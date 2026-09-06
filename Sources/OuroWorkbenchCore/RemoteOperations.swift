import CryptoKit
import Darwin
import Foundation

public enum RemoteHealthState: String, Codable, CaseIterable, Equatable, Sendable {
    case healthy
    case degraded
    case blocked
    case unknown
    case unavailable
    case tripped
    case corrupt
    case accountMismatch = "account_mismatch"
}

public enum RemoteHealthFreshness: String, Codable, Equatable, Sendable {
    case fresh
    case stale
    case unknown
}

public struct RemoteHealthCheck: Codable, Equatable, Sendable {
    public var name: String
    public var source: String
    public var observedAt: Date?
    public var state: RemoteHealthState
    public var detail: String

    public init(name: String, source: String, observedAt: Date?, state: RemoteHealthState, detail: String) {
        self.name = name
        self.source = source
        self.observedAt = observedAt
        self.state = state
        self.detail = detail
    }
}

public struct RemoteDoctorCheck: Codable, Equatable, Sendable {
    public var name: String
    public var source: String
    public var observedAt: Date?
    public var freshness: RemoteHealthFreshness
    public var state: RemoteHealthState
    public var detail: String
}

public struct RemoteDoctorReport: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var checks: [RemoteDoctorCheck]

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

public enum RemoteDoctor {
    public static func report(
        checks: [RemoteHealthCheck],
        now: Date,
        staleAfter: TimeInterval,
        redacting secrets: [String]
    ) -> RemoteDoctorReport {
        let secrets = secrets.filter { !$0.isEmpty }
        return RemoteDoctorReport(
            generatedAt: now,
            checks: checks.map { check in
                let freshness: RemoteHealthFreshness
                if let observedAt = check.observedAt {
                    freshness = now.timeIntervalSince(observedAt) > staleAfter ? .stale : .fresh
                } else {
                    freshness = .unknown
                }
                return RemoteDoctorCheck(
                    name: remoteRedact(check.name, secrets: secrets),
                    source: remoteRedact(check.source, secrets: secrets),
                    observedAt: check.observedAt,
                    freshness: freshness,
                    state: freshness == .stale && check.state == .healthy ? .unknown : check.state,
                    detail: remoteRedact(check.detail, secrets: secrets)
                )
            }
        )
    }
}

public struct RemoteObserver {
    public let rootURL: URL
    public let maximumBytes: Int
    private let writer: (Data, URL) throws -> Void

    public init(
        rootURL: URL,
        maximumBytes: Int = 64 * 1_024,
        writer: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.maximumBytes = maximumBytes
        self.writer = writer
    }

    public func record(
        checks: [RemoteHealthCheck],
        observedAt: Date,
        redacting secrets: [String] = []
    ) throws -> URL {
        guard maximumBytes > 0 else {
            throw RemoteControlError.observation("observer requires a positive byte bound")
        }
        struct Observation: Codable {
            var observedAt: Date
            var checks: [RemoteHealthCheck]
        }
        let safeSecrets = secrets.filter { !$0.isEmpty }
        let safeChecks = checks.map {
            RemoteHealthCheck(
                name: remoteRedact($0.name, secrets: safeSecrets),
                source: remoteRedact($0.source, secrets: safeSecrets),
                observedAt: $0.observedAt,
                state: $0.state,
                detail: remoteRedact($0.detail, secrets: safeSecrets)
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Observation(observedAt: observedAt, checks: safeChecks))
        guard data.count <= maximumBytes else {
            throw RemoteControlError.observation("observation exceeds the configured byte bound")
        }

        let observationsURL = rootURL.appendingPathComponent("observations", isDirectory: true)
        let outputURL = observationsURL.appendingPathComponent("latest.json")
        do {
            try remoteEnsureDirectory(rootURL, mode: 0o700, label: "observer root", domain: .observation)
            try remoteEnsureDirectory(observationsURL, mode: 0o700, label: "observations directory", domain: .observation)
            if try remoteMetadata(at: outputURL, label: "observation target", domain: .observation) != nil {
                _ = try remoteRequireRegular(outputURL, label: "observation target", domain: .observation)
            }
            try writer(data, outputURL)
            let written = try remoteRequireRegular(outputURL, label: "observation target", domain: .observation)
            guard written.size <= maximumBytes else {
                throw RemoteControlError.observation("written observation exceeds the configured byte bound")
            }
            try remoteSetPermissions(0o600, at: outputURL, label: "observation target", domain: .observation)
        } catch let error as RemoteControlError {
            throw error
        } catch {
            throw RemoteControlError.observation("observation write failed")
        }
        return outputURL
    }
}

public struct RemoteArtifactFile: Codable, Equatable, Sendable {
    public var relativePath: String
    public var sha256: String
    public var mode: Int

    public init(relativePath: String, sha256: String, mode: Int) {
        self.relativePath = relativePath
        self.sha256 = sha256
        self.mode = mode
    }
}

public struct RemoteArtifactManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var revision: String
    public var files: [RemoteArtifactFile]

    public init(schemaVersion: Int, revision: String, files: [RemoteArtifactFile]) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.files = files
    }
}

public enum RemoteArtifactBuildCheckpoint: String, CaseIterable, Codable, Equatable, Sendable {
    case copied
    case manifestWritten
    case promoted
}

public enum RemoteArtifactBuilder {
    public static func build(
        helperURL: URL,
        outputURL: URL,
        sourceRootURL: URL,
        revision: String,
        expectedHelperSHA256: String,
        checkpoint: (RemoteArtifactBuildCheckpoint) throws -> Void = { _ in }
    ) throws -> RemoteArtifactManifest {
        guard remoteIsRevision(revision) else {
            throw RemoteControlError.artifact("artifact revision is invalid")
        }
        guard remoteIsSHA256(expectedHelperSHA256) else {
            throw RemoteControlError.artifact("trusted helper digest is invalid")
        }
        let sourceRoot: RemotePhysicalDirectory
        do {
            sourceRoot = try remotePhysicalDirectory(sourceRootURL, label: "trusted source root", domain: .artifact)
        } catch {
            throw RemoteControlError.artifact("trusted source HEAD could not be verified")
        }
        let sourceRevision = try remoteTrustedSourceRevision(rootURL: sourceRoot.physicalURL)
        guard revision == sourceRevision else {
            throw RemoteControlError.artifact("artifact revision does not match the clean source HEAD")
        }
        let requestedHelperURL = helperURL.standardizedFileURL
        let requestedOutputURL = outputURL.standardizedFileURL
        let helper = try remoteRequireRegular(requestedHelperURL, label: "helper", domain: .artifact)
        guard helper.permissions == 0o755 else {
            throw RemoteControlError.artifact("helper must be executable with mode 0755")
        }
        guard try remoteMetadata(at: requestedOutputURL, label: "artifact output", domain: .artifact) == nil else {
            throw RemoteControlError.artifact("artifact output must be a new path")
        }
        let outputParent = try remotePhysicalDirectory(
            requestedOutputURL.deletingLastPathComponent(),
            label: "artifact output parent",
            domain: .artifact
        )
        let outputURL = outputParent.physicalURL.appendingPathComponent(requestedOutputURL.lastPathComponent, isDirectory: true)
        let physicalHelperURL = try remotePhysicalRegularURL(requestedHelperURL, label: "helper", domain: .artifact)
        let helperData = try remoteReadData(at: physicalHelperURL, label: "helper")
        let helperSHA256 = RemoteArtifactVerifier.sha256(helperData)
        guard helperSHA256 == expectedHelperSHA256 else {
            throw RemoteControlError.artifact("helper does not match the trusted helper digest")
        }
        let manifest = RemoteArtifactManifest(
            schemaVersion: 1,
            revision: sourceRevision,
            files: [
                RemoteArtifactFile(
                    relativePath: "bin/OuroWorkbenchRemote",
                    sha256: helperSHA256,
                    mode: 0o755
                )
            ]
        )
        let stageURL = outputParent.physicalURL.appendingPathComponent(".\(outputURL.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        var cleanupURL: URL? = stageURL
        do {
            try remoteEnsureDirectory(stageURL, mode: 0o700, label: "artifact staging root", domain: .artifact)
            try remoteWriteRuntimeFile(helperData, relativePath: "bin/OuroWorkbenchRemote", mode: 0o755, rootURL: stageURL)
            try remoteArtifactBuildCheckpoint(.copied, callback: checkpoint)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let manifestURL = stageURL.appendingPathComponent("manifest.json")
            try remoteWriteData(try encoder.encode(manifest), to: manifestURL, label: "artifact manifest")
            _ = try remoteRequireRegular(manifestURL, label: "artifact manifest", domain: .artifact)
            try remoteSetPermissions(0o600, at: manifestURL, label: "artifact manifest", domain: .artifact)
            try remoteArtifactBuildCheckpoint(.manifestWritten, callback: checkpoint)

            try remoteRevalidatePhysicalDirectory(sourceRoot, label: "trusted source root", domain: .artifact)
            guard try remoteTrustedSourceRevision(rootURL: sourceRoot.physicalURL) == sourceRevision else {
                throw RemoteControlError.artifact("trusted source HEAD changed during packaging")
            }
            try remoteRevalidatePhysicalDirectory(outputParent, label: "artifact output parent", domain: .artifact)
            do {
                let stagedManifest = try RemoteArtifactVerifier.load(rootURL: stageURL)
                guard stagedManifest == manifest else {
                    throw RemoteControlError.artifact("staged artifact manifest changed before promotion")
                }
                try remoteVerifyExactArtifactTree(rootURL: stageURL, manifest: manifest)
            } catch {
                throw RemoteControlError.artifact("staged artifact does not match the verified package")
            }

            do {
                try FileManager.default.moveItem(at: stageURL, to: outputURL)
            } catch {
                throw RemoteControlError.artifact("artifact could not be promoted")
            }
            cleanupURL = outputURL
            try remoteArtifactBuildCheckpoint(.promoted, callback: checkpoint)
            let verified = try RemoteArtifactVerifier.load(rootURL: outputURL)
            guard verified == manifest else {
                throw RemoteControlError.artifact("promoted artifact manifest changed after verification")
            }
            try remoteVerifyExactArtifactTree(rootURL: outputURL, manifest: manifest)
            cleanupURL = nil
            return manifest
        } catch {
            if let cleanupURL, try remoteMetadata(at: cleanupURL, label: "incomplete artifact", domain: .artifact) != nil {
                try remoteRemoveItem(cleanupURL, label: "incomplete artifact")
            }
            throw error
        }
    }
}

public enum RemoteArtifactVerifier {
    public static let maximumManifestBytes = 1_048_576

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func load(rootURL: URL) throws -> RemoteArtifactManifest {
        let rootURL = rootURL.standardizedFileURL
        guard try remoteMetadata(at: rootURL, label: "artifact root", domain: .artifact) != nil else {
            throw RemoteControlError.artifact("artifact manifest is missing")
        }
        _ = try remoteRequireDirectory(rootURL, label: "artifact root", domain: .artifact)
        let manifestURL = rootURL.appendingPathComponent("manifest.json")
        guard try remoteMetadata(at: manifestURL, label: "artifact manifest", domain: .artifact) != nil else {
            throw RemoteControlError.artifact("artifact manifest is missing")
        }
        let metadata = try remoteRequireRegular(manifestURL, label: "artifact manifest", domain: .artifact)
        guard metadata.size <= maximumManifestBytes else {
            throw RemoteControlError.artifact("artifact manifest exceeds the configured byte bound")
        }
        let data = try remoteReadData(at: manifestURL, label: "artifact manifest")
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RemoteControlError.artifact("artifact manifest is invalid JSON")
        }
        guard let object = raw as? [String: Any] else {
            throw RemoteControlError.artifact("artifact manifest top level must be an object")
        }
        let allowedKeys = Set(["schemaVersion", "revision", "files"])
        if !Set(object.keys).subtracting(allowedKeys).isEmpty {
            throw RemoteControlError.artifact("unknown artifact key")
        }
        guard let rawFiles = object["files"] as? [[String: Any]] else {
            throw RemoteControlError.artifact("artifact manifest has invalid fields")
        }
        let allowedFileKeys = Set(["relativePath", "sha256", "mode"])
        for file in rawFiles {
            if !Set(file.keys).subtracting(allowedFileKeys).isEmpty {
                throw RemoteControlError.artifact("unknown file key")
            }
        }
        let manifest: RemoteArtifactManifest
        do {
            manifest = try JSONDecoder().decode(RemoteArtifactManifest.self, from: data)
        } catch {
            throw RemoteControlError.artifact("artifact manifest has invalid fields")
        }
        guard manifest.schemaVersion == 1,
              remoteIsRevision(manifest.revision),
              !manifest.files.isEmpty
        else {
            throw RemoteControlError.artifact("artifact manifest identity is invalid")
        }
        var paths = Set<Data>()
        var portablePaths = Set<String>()
        for file in manifest.files {
            try remoteValidateRelativePath(file.relativePath)
            guard paths.insert(Data(file.relativePath.utf8)).inserted else {
                throw RemoteControlError.artifact("artifact file path is duplicate")
            }
            guard portablePaths.insert(remotePortablePathKey(file.relativePath)).inserted else {
                throw RemoteControlError.artifact("artifact file has a portable path collision")
            }
            guard remoteIsSHA256(file.sha256) else {
                throw RemoteControlError.artifact("artifact file hash is invalid")
            }
            guard file.mode == 0o755 || file.mode == 0o644 else {
                throw RemoteControlError.artifact("artifact file mode is invalid")
            }
        }
        let executableFiles = manifest.files.filter { $0.mode == 0o755 }
        guard executableFiles.count == 1,
              executableFiles[0].relativePath == "bin/OuroWorkbenchRemote"
        else {
            throw RemoteControlError.artifact("artifact must contain exactly one executable helper")
        }
        return manifest
    }
}

public enum RemoteInstallOwnership: String, Codable, Equatable, Sendable {
    case created
    case adopted
}

public struct RemoteProvenanceEntry: Codable, Equatable, Sendable {
    public var path: String
    public var sha256: String
    public var ownership: RemoteInstallOwnership
}

public struct RemoteProvenanceManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var revision: String
    public var runtimeRoot: String
    public var entries: [RemoteProvenanceEntry]
}

public enum RemoteInstallCheckpoint: String, CaseIterable, Codable, Equatable, Sendable {
    case verified
    case copied
    case promoted
}

public enum RemoteRollbackResult: Equatable, Sendable {
    case retainedForNativeResume
    case preservedAdopted
    case removed
}

public struct RemoteRuntimeInstaller {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func install(
        artifactRoot: URL,
        expectedRevision: String,
        expectedHelperSHA256: String,
        checkpoint: (RemoteInstallCheckpoint) throws -> Void = { _ in }
    ) throws -> RemoteProvenanceManifest {
        guard remoteIsSHA256(expectedHelperSHA256) else {
            throw RemoteControlError.artifact("trusted helper digest is invalid")
        }
        let artifactRootAnchor = try remotePhysicalDirectory(
            artifactRoot,
            label: "artifact root",
            domain: .artifact
        )
        let artifactRoot = artifactRootAnchor.physicalURL
        let manifest = try RemoteArtifactVerifier.load(rootURL: artifactRoot)
        guard manifest.revision == expectedRevision else {
            throw RemoteControlError.artifact("artifact revision does not match the expected revision")
        }
        guard manifest.files.first(where: { $0.relativePath == "bin/OuroWorkbenchRemote" })?.sha256 == expectedHelperSHA256 else {
            throw RemoteControlError.artifact("artifact does not match the trusted helper digest")
        }
        let sourceData = try manifest.files.map { file -> (RemoteArtifactFile, Data) in
            let source = try remoteArtifactFileURL(rootURL: artifactRoot, relativePath: file.relativePath)
            let data = try remoteReadData(at: source, label: "artifact file")
            guard RemoteArtifactVerifier.sha256(data) == file.sha256 else {
                throw RemoteControlError.artifact("artifact checksum mismatch")
            }
            return (file, data)
        }
        try remoteVerifyExactArtifactTree(rootURL: artifactRoot, manifest: manifest)
        try remoteRevalidatePhysicalDirectory(artifactRootAnchor, label: "artifact root", domain: .artifact)
        try remoteCheckpoint(.verified, callback: checkpoint)

        try remoteEnsureDirectory(rootURL, mode: 0o700, label: "runtime root", domain: .artifact)
        let runtimeRootAnchor = try remotePhysicalDirectory(rootURL, label: "runtime root", domain: .artifact)
        let runtimeRootURL = runtimeRootAnchor.physicalURL
        _ = try remoteReadCurrentRevisionIfPresent(runtimeRootURL.appendingPathComponent("current"))
        let versionsRoot = runtimeRootURL.appendingPathComponent("versions", isDirectory: true)
        try remoteEnsureDirectory(versionsRoot, mode: 0o700, label: "versions root", domain: .artifact)
        let versionRoot = versionsRoot.appendingPathComponent(manifest.revision, isDirectory: true)
        let versionMetadata = try remoteMetadata(at: versionRoot, label: "runtime version", domain: .artifact)

        let provenance: RemoteProvenanceManifest
        let needsManifestWrite: Bool
        var stagedRoot: URL?
        if versionMetadata == nil {
            let stage = versionsRoot.appendingPathComponent(".install-\(manifest.revision)-\(UUID().uuidString)", isDirectory: true)
            try remoteEnsureDirectory(stage, mode: 0o700, label: "runtime staging root", domain: .artifact)
            let entries = sourceData.map { file, _ in
                RemoteProvenanceEntry(
                    path: versionRoot.appendingPathComponent(file.relativePath).path,
                    sha256: file.sha256,
                    ownership: .created
                )
            }
            provenance = RemoteProvenanceManifest(schemaVersion: 1, revision: manifest.revision, runtimeRoot: runtimeRootURL.path, entries: entries)
            for (file, data) in sourceData {
                try remoteWriteRuntimeFile(data, relativePath: file.relativePath, mode: file.mode, rootURL: stage)
            }
            try remoteWriteProvenance(provenance, at: stage.appendingPathComponent("install-manifest.json"))
            stagedRoot = stage
            needsManifestWrite = false
        } else {
            _ = try remoteRequireDirectory(versionRoot, label: "runtime version", domain: .artifact)
            let installedManifestURL = versionRoot.appendingPathComponent("install-manifest.json")
            if try remoteMetadata(at: installedManifestURL, label: "install provenance", domain: .artifact) != nil {
                provenance = try remoteReadProvenance(at: installedManifestURL, rootURL: runtimeRootURL)
                try remoteVerifyInstalledArtifact(manifest, provenance: provenance, versionRoot: versionRoot)
                needsManifestWrite = false
            } else {
                for (file, _) in sourceData {
                    let destination: URL
                    do {
                        destination = try remoteRuntimeFileURL(rootURL: versionRoot, relativePath: file.relativePath)
                    } catch {
                        throw RemoteControlError.artifact("artifact conflicts with an incomplete preexisting version")
                    }
                    guard try remoteMetadata(at: destination, label: "preexisting runtime file", domain: .artifact) != nil else {
                        throw RemoteControlError.artifact("artifact conflicts with an incomplete preexisting version")
                    }
                    let metadata = try remoteRequireRegular(destination, label: "preexisting runtime file", domain: .artifact)
                    let data = try remoteReadData(at: destination, label: "preexisting runtime file")
                    guard metadata.permissions == file.mode,
                          RemoteArtifactVerifier.sha256(data) == file.sha256
                    else {
                        throw RemoteControlError.artifact("artifact conflicts with an incomplete preexisting version")
                    }
                }
                provenance = RemoteProvenanceManifest(
                    schemaVersion: 1,
                    revision: manifest.revision,
                    runtimeRoot: runtimeRootURL.path,
                    entries: manifest.files.map {
                        RemoteProvenanceEntry(
                            path: versionRoot.appendingPathComponent($0.relativePath).path,
                            sha256: $0.sha256,
                            ownership: .adopted
                        )
                    }
                )
                needsManifestWrite = true
            }
        }

        do {
            try remoteCheckpoint(.copied, callback: checkpoint)
        } catch {
            if let stagedRoot {
                try remoteRemoveItem(stagedRoot, label: "runtime staging root")
            }
            throw error
        }
        do {
            try remoteRevalidatePhysicalDirectory(runtimeRootAnchor, label: "runtime root", domain: .artifact)
        } catch {
            if let stagedRoot {
                try remoteRemoveItem(stagedRoot, label: "runtime staging root")
            }
            throw error
        }
        if let stagedRoot {
            do {
                try remoteVerifyStagedRuntime(
                    rootURL: stagedRoot,
                    manifest: manifest,
                    provenance: provenance,
                    runtimeRootURL: runtimeRootURL
                )
            } catch {
                try remoteRemoveItem(stagedRoot, label: "runtime staging root")
                throw RemoteControlError.artifact("staged runtime does not match the verified artifact")
            }
            do {
                try FileManager.default.moveItem(at: stagedRoot, to: versionRoot)
            } catch {
                try remoteRemoveItem(stagedRoot, label: "runtime staging root")
                throw RemoteControlError.artifact("artifact could not be installed into the versioned runtime")
            }
        } else if needsManifestWrite {
            try remoteVerifyRuntimePayload(manifest, rootURL: versionRoot, additionalExpectedFiles: [:])
            try remoteWriteProvenance(provenance, at: versionRoot.appendingPathComponent("install-manifest.json"))
        }

        try remoteVerifyInstalledArtifact(manifest, provenance: provenance, versionRoot: versionRoot)

        try remoteCheckpoint(.promoted, callback: checkpoint)
        try remoteRevalidatePhysicalDirectory(runtimeRootAnchor, label: "runtime root", domain: .artifact)
        try remoteVerifyInstalledArtifact(manifest, provenance: provenance, versionRoot: versionRoot)
        try remoteWriteCurrentRevision(manifest.revision, rootURL: runtimeRootURL)
        return provenance
    }

    public func rollback(
        provenance: RemoteProvenanceManifest,
        nativeSessionReferencesRemain: Bool,
        physicalValidationCheckpoint: () throws -> Void = {}
    ) throws -> RemoteRollbackResult {
        let physicalCandidate = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let versionRoot = try remoteValidateProvenance(provenance, rootURL: physicalCandidate)
        if try remoteMetadata(at: rootURL, label: "runtime root", domain: .artifact) == nil {
            return .removed
        }
        try physicalValidationCheckpoint()
        let runtimeRoot = try remotePhysicalDirectory(rootURL, label: "runtime root", domain: .artifact)
        guard runtimeRoot.physicalURL.path == physicalCandidate.path else {
            throw RemoteControlError.artifact("runtime root physical location changed")
        }

        let pointer = runtimeRoot.physicalURL.appendingPathComponent("current")
        let currentRevision = try remoteReadCurrentRevisionIfPresent(pointer)
        if try remoteMetadata(at: versionRoot, label: "runtime version", domain: .artifact) != nil {
            _ = try remoteRequireDirectory(versionRoot, label: "runtime version", domain: .artifact)
            let installed = try remoteReadProvenance(at: versionRoot.appendingPathComponent("install-manifest.json"), rootURL: rootURL)
            guard installed == provenance else {
                throw RemoteControlError.artifact("installed provenance does not match rollback provenance")
            }
            for entry in provenance.entries {
                let relativePath = String(entry.path.dropFirst(versionRoot.path.count + 1))
                let url = try remoteRuntimeFileURL(rootURL: versionRoot, relativePath: relativePath)
                _ = try remoteRequireRegular(url, label: "runtime file", domain: .artifact)
                guard RemoteArtifactVerifier.sha256(try remoteReadData(at: url, label: "runtime file")) == entry.sha256 else {
                    throw RemoteControlError.artifact("runtime file changed after installation")
                }
            }
            let expectedFiles = Set(provenance.entries.map { URL(fileURLWithPath: $0.path).path })
                .union([versionRoot.appendingPathComponent("install-manifest.json").path])
            let subpaths = try FileManager.default.subpathsOfDirectory(atPath: versionRoot.path)
            for subpath in subpaths {
                let url = versionRoot.appendingPathComponent(subpath)
                let metadata = try remoteMetadata(at: url, label: "runtime version item", domain: .artifact)
                if metadata?.kind != .directory, !expectedFiles.contains(url.path) {
                    throw RemoteControlError.artifact("runtime version contains an unowned file")
                }
            }
        }
        if currentRevision == provenance.revision {
            return .retainedForNativeResume
        }
        if nativeSessionReferencesRemain {
            return .retainedForNativeResume
        }
        if provenance.entries.contains(where: { $0.ownership == .adopted }) {
            return .preservedAdopted
        }
        try remoteRevalidatePhysicalDirectory(runtimeRoot, label: "runtime root", domain: .artifact)
        if try remoteMetadata(at: versionRoot, label: "runtime version", domain: .artifact) != nil {
            try remoteRemoveItem(versionRoot, label: "runtime version")
        }
        return .removed
    }
}

enum RemoteFilesystemDomain {
    case observation
    case artifact

    func error(_ detail: String) -> RemoteControlError {
        switch self {
        case .observation: .observation(detail)
        case .artifact: .artifact(detail)
        }
    }
}

private struct RemoteFileMetadata {
    enum Kind {
        case regular
        case directory
        case symbolicLink
        case other
    }

    var kind: Kind
    var size: Int
    var permissions: Int
    var linkCount: UInt64
}

private struct RemotePhysicalDirectory {
    var requestedURL: URL
    var physicalURL: URL
}

private func remoteMetadata(at url: URL, label: String, domain: RemoteFilesystemDomain) throws -> RemoteFileMetadata? {
    var value = stat()
    let result = url.path.withCString { lstat($0, &value) }
    if result != 0 {
        if errno == ENOENT {
            return nil
        }
        throw domain.error("\(label) could not be inspected")
    }
    let fileType = value.st_mode & mode_t(S_IFMT)
    let kind: RemoteFileMetadata.Kind
    switch fileType {
    case mode_t(S_IFREG): kind = .regular
    case mode_t(S_IFDIR): kind = .directory
    case mode_t(S_IFLNK): kind = .symbolicLink
    default: kind = .other
    }
    return RemoteFileMetadata(
        kind: kind,
        size: Int(value.st_size),
        permissions: Int(value.st_mode & 0o777),
        linkCount: UInt64(value.st_nlink)
    )
}

@discardableResult
private func remoteRequireRegular(_ url: URL, label: String, domain: RemoteFilesystemDomain) throws -> RemoteFileMetadata {
    guard let metadata = try remoteMetadata(at: url, label: label, domain: domain) else {
        throw domain.error("\(label) is missing")
    }
    guard metadata.kind == .regular else {
        let reason = metadata.kind == .symbolicLink ? "must be a regular file, not a symbolic link" : "must be a regular file"
        throw domain.error("\(label) \(reason)")
    }
    guard metadata.linkCount == 1 else {
        throw domain.error("\(label) has multiple links")
    }
    return metadata
}

@discardableResult
private func remoteRequireDirectory(_ url: URL, label: String, domain: RemoteFilesystemDomain) throws -> RemoteFileMetadata {
    guard let metadata = try remoteMetadata(at: url, label: label, domain: domain) else {
        throw domain.error("\(label) is missing")
    }
    guard metadata.kind == .directory else {
        throw domain.error("\(label) must be a directory and not a symbolic link")
    }
    return metadata
}

private func remotePhysicalDirectory(
    _ requestedURL: URL,
    label: String,
    domain: RemoteFilesystemDomain
) throws -> RemotePhysicalDirectory {
    let requestedURL = requestedURL.standardizedFileURL
    _ = try remoteRequireDirectory(requestedURL, label: label, domain: domain)
    let physicalURL = requestedURL.resolvingSymlinksInPath().standardizedFileURL
    _ = try remoteRequireDirectory(physicalURL, label: label, domain: domain)
    return RemotePhysicalDirectory(requestedURL: requestedURL, physicalURL: physicalURL)
}

private func remoteRevalidatePhysicalDirectory(
    _ anchor: RemotePhysicalDirectory,
    label: String,
    domain: RemoteFilesystemDomain
) throws {
    do {
        let current = try remotePhysicalDirectory(anchor.requestedURL, label: label, domain: domain)
        guard current.physicalURL.path == anchor.physicalURL.path else {
            throw domain.error("\(label) physical location changed")
        }
    } catch {
        throw domain.error("\(label) physical location changed")
    }
}

private func remotePhysicalRegularURL(_ requestedURL: URL, label: String, domain: RemoteFilesystemDomain) throws -> URL {
    let requestedURL = requestedURL.standardizedFileURL
    _ = try remoteRequireRegular(requestedURL, label: label, domain: domain)
    let physicalURL = requestedURL.resolvingSymlinksInPath().standardizedFileURL
    _ = try remoteRequireRegular(physicalURL, label: label, domain: domain)
    return physicalURL
}

func remoteRequirePhysicalContainment(
    _ url: URL,
    in rootURL: URL,
    label: String,
    domain: RemoteFilesystemDomain
) throws {
    let physicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
    let physicalURL = url.resolvingSymlinksInPath().standardizedFileURL.path
    guard physicalURL == physicalRoot || physicalURL.hasPrefix(physicalRoot + "/") else {
        throw domain.error("\(label) escapes its physical root")
    }
}

private func remoteEnsureDirectory(_ url: URL, mode: Int, label: String, domain: RemoteFilesystemDomain) throws {
    if try remoteMetadata(at: url, label: label, domain: domain) == nil {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw domain.error("\(label) could not be created")
        }
    }
    _ = try remoteRequireDirectory(url, label: label, domain: domain)
    try remoteSetPermissions(mode, at: url, label: label, domain: domain)
}

private func remoteSetPermissions(_ mode: Int, at url: URL, label: String, domain: RemoteFilesystemDomain) throws {
    do {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    } catch {
        throw domain.error("\(label) permissions could not be secured")
    }
}

private func remoteRedact(_ value: String, secrets: [String]) -> String {
    secrets.reduce(value) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
}

private func remoteIsRevision(_ value: String) -> Bool {
    value.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
}

private func remoteIsSHA256(_ value: String) -> Bool {
    value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
}

private func remotePortablePathKey(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping
        .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .precomposedStringWithCanonicalMapping
}

private func remoteValidateRelativePath(_ path: String) throws {
    guard !path.isEmpty else {
        throw RemoteControlError.artifact("artifact file path is empty")
    }
    guard !path.hasPrefix("/") else {
        throw RemoteControlError.artifact("artifact file path is absolute")
    }
    guard !path.unicodeScalars.contains(where: { $0.value == 0 }) else {
        throw RemoteControlError.artifact("artifact file path contains a null byte")
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.contains(where: { $0.isEmpty }) else {
        throw RemoteControlError.artifact("artifact file path has an empty component")
    }
    guard !components.contains(".") else {
        throw RemoteControlError.artifact("artifact file path has a dot component")
    }
    guard !components.contains("..") else {
        throw RemoteControlError.artifact("artifact file path contains traversal")
    }
}

private func remoteArtifactFileURL(rootURL: URL, relativePath: String) throws -> URL {
    let components = relativePath.split(separator: "/").map(String.init)
    let physicalRoot = try remotePhysicalDirectory(rootURL, label: "artifact root", domain: .artifact).physicalURL
    var current = physicalRoot
    for component in components.dropLast() {
        current.appendPathComponent(component, isDirectory: true)
        _ = try remoteRequireDirectory(current, label: "artifact directory", domain: .artifact)
        try remoteRequirePhysicalContainment(current, in: physicalRoot, label: "artifact directory", domain: .artifact)
    }
    current.appendPathComponent(components.last!)
    _ = try remoteRequireRegular(current, label: "artifact file", domain: .artifact)
    try remoteRequirePhysicalContainment(current, in: physicalRoot, label: "artifact file", domain: .artifact)
    return current
}

private func remoteRuntimeFileURL(rootURL: URL, relativePath: String) throws -> URL {
    let components = relativePath.split(separator: "/").map(String.init)
    let physicalRoot = try remotePhysicalDirectory(rootURL, label: "runtime root", domain: .artifact).physicalURL
    var current = physicalRoot
    for component in components.dropLast() {
        current.appendPathComponent(component, isDirectory: true)
        _ = try remoteRequireDirectory(current, label: "runtime directory", domain: .artifact)
        try remoteRequirePhysicalContainment(current, in: physicalRoot, label: "runtime directory", domain: .artifact)
    }
    current.appendPathComponent(components.last!)
    try remoteRequirePhysicalContainment(current.deletingLastPathComponent(), in: physicalRoot, label: "runtime file parent", domain: .artifact)
    return current
}

private func remoteWriteRuntimeFile(_ data: Data, relativePath: String, mode: Int, rootURL: URL) throws {
    let components = relativePath.split(separator: "/").map(String.init)
    let physicalRoot = try remotePhysicalDirectory(rootURL, label: "runtime root", domain: .artifact).physicalURL
    var directory = physicalRoot
    for component in components.dropLast() {
        directory.appendPathComponent(component, isDirectory: true)
        try remoteEnsureDirectory(directory, mode: 0o700, label: "runtime directory", domain: .artifact)
        try remoteRequirePhysicalContainment(directory, in: physicalRoot, label: "runtime directory", domain: .artifact)
    }
    let destination = directory.appendingPathComponent(components.last!)
    try remoteWriteData(data, to: destination, label: "runtime file")
    _ = try remoteRequireRegular(destination, label: "runtime file", domain: .artifact)
    try remoteSetPermissions(mode, at: destination, label: "runtime file", domain: .artifact)
}

func remoteTrustedSourceRevision(
    rootURL: URL,
    runGit: (([String]) throws -> RemoteProcessResult)? = nil
) throws -> String {
    let sourceRoot = try remotePhysicalDirectory(rootURL, label: "trusted source root", domain: .artifact).physicalURL
    let execute = runGit ?? { arguments in
        try RemoteSystemRunner(timeout: 10, maximumOutputBytes: 1_048_576).run(
            RemoteProcessRequest(
                executable: "/usr/bin/git",
                arguments: ["-C", sourceRoot.path] + arguments,
                environment: [
                    "GIT_CONFIG_GLOBAL": "/dev/null",
                    "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_OPTIONAL_LOCKS": "0",
                    "HOME": "/var/empty",
                    "LANG": "C",
                    "LC_ALL": "C",
                    "PATH": "/usr/bin:/bin"
                ]
            )
        )
    }

    func git(_ arguments: [String]) throws -> String {
        let result: RemoteProcessResult
        do {
            result = try execute(arguments)
        } catch {
            throw RemoteControlError.artifact("trusted source HEAD could not be verified")
        }
        guard result.exitCode == 0 else {
            throw RemoteControlError.artifact("trusted source HEAD could not be verified")
        }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let topLevel = try git(["rev-parse", "--show-toplevel"])
    guard URL(fileURLWithPath: topLevel, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path == sourceRoot.path else {
        throw RemoteControlError.artifact("trusted source root must be the exact Git worktree root")
    }
    let revision = try git(["rev-parse", "--verify", "HEAD^{commit}"])
    guard remoteIsRevision(revision) else {
        throw RemoteControlError.artifact("trusted source HEAD could not be verified")
    }
    guard try git(["status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"]).isEmpty else {
        throw RemoteControlError.artifact("source checkout is not clean")
    }
    guard try git(["rev-parse", "--verify", "HEAD^{commit}"]) == revision else {
        throw RemoteControlError.artifact("trusted source HEAD changed during verification")
    }
    return revision
}

private func remoteVerifyExactArtifactTree(rootURL: URL, manifest: RemoteArtifactManifest) throws {
    let root = try remotePhysicalDirectory(rootURL, label: "artifact root", domain: .artifact).physicalURL
    let rootMetadata = try remoteRequireDirectory(root, label: "artifact root", domain: .artifact)
    guard rootMetadata.permissions == 0o700 else {
        throw RemoteControlError.artifact("artifact root permissions do not match the package")
    }
    let manifestURL = root.appendingPathComponent("manifest.json")
    let manifestMetadata = try remoteRequireRegular(manifestURL, label: "artifact manifest", domain: .artifact)
    guard manifestMetadata.permissions == 0o600 else {
        throw RemoteControlError.artifact("artifact manifest permissions do not match the package")
    }

    var expectedFiles = Set([manifestURL.path])
    var expectedDirectories = Set<String>()
    for file in manifest.files {
        let url = try remoteArtifactFileURL(rootURL: root, relativePath: file.relativePath)
        let metadata = try remoteRequireRegular(url, label: "artifact file", domain: .artifact)
        guard metadata.permissions == file.mode,
              RemoteArtifactVerifier.sha256(try remoteReadData(at: url, label: "artifact file")) == file.sha256
        else {
            throw RemoteControlError.artifact("artifact file does not match its manifest")
        }
        expectedFiles.insert(url.path)
        var directory = url.deletingLastPathComponent()
        while directory.path != root.path {
            expectedDirectories.insert(directory.path)
            directory.deleteLastPathComponent()
        }
    }
    for path in expectedDirectories {
        let metadata = try remoteRequireDirectory(URL(fileURLWithPath: path, isDirectory: true), label: "artifact directory", domain: .artifact)
        guard metadata.permissions == 0o700 else {
            throw RemoteControlError.artifact("artifact directory permissions do not match the package")
        }
    }
    try remoteVerifyExactTreeInventory(
        rootURL: root,
        expectedFiles: expectedFiles,
        expectedDirectories: expectedDirectories,
        label: "artifact"
    )
}

func remoteVerifyExactTreeInventory(
    rootURL: URL,
    expectedFiles: Set<String>,
    expectedDirectories: Set<String>,
    label: String,
    inspectionCheckpoint: (URL) throws -> Void = { _ in }
) throws {
    let subpaths: [String]
    do {
        subpaths = try FileManager.default.subpathsOfDirectory(atPath: rootURL.path)
    } catch {
        throw RemoteControlError.artifact("\(label) tree could not be inspected")
    }
    for subpath in subpaths {
        let url = rootURL.appendingPathComponent(subpath)
        try remoteRequirePhysicalContainment(url, in: rootURL, label: "\(label) item", domain: .artifact)
        try inspectionCheckpoint(url)
        guard let metadata = try remoteMetadata(at: url, label: "\(label) item", domain: .artifact) else {
            throw RemoteControlError.artifact("\(label) tree changed during inspection")
        }
        switch metadata.kind {
        case .directory:
            guard expectedDirectories.contains(url.path) else {
                throw RemoteControlError.artifact("\(label) contains an unowned directory")
            }
        case .regular:
            _ = try remoteRequireRegular(url, label: "\(label) file", domain: .artifact)
            guard expectedFiles.contains(url.path) else {
                throw RemoteControlError.artifact("\(label) contains an unowned file")
            }
        case .symbolicLink, .other:
            throw RemoteControlError.artifact("\(label) contains a special entry")
        }
    }
}

private func remoteWriteProvenance(_ provenance: RemoteProvenanceManifest, at url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(provenance)
    try remoteWriteData(data, to: url, label: "install provenance")
    _ = try remoteRequireRegular(url, label: "install provenance", domain: .artifact)
    try remoteSetPermissions(0o600, at: url, label: "install provenance", domain: .artifact)
}

private func remoteReadProvenance(at url: URL, rootURL: URL) throws -> RemoteProvenanceManifest {
    let metadata = try remoteRequireRegular(url, label: "install provenance", domain: .artifact)
    guard metadata.size <= RemoteArtifactVerifier.maximumManifestBytes else {
        throw RemoteControlError.artifact("install provenance exceeds the configured byte bound")
    }
    let data = try remoteReadData(at: url, label: "install provenance")
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw RemoteControlError.artifact("install provenance is invalid")
    }
    let allowedKeys = Set(["schemaVersion", "revision", "runtimeRoot", "entries"])
    guard Set(object.keys).subtracting(allowedKeys).isEmpty,
          let entries = object["entries"] as? [[String: Any]],
          entries.allSatisfy({ Set($0.keys).subtracting(["path", "sha256", "ownership"]).isEmpty })
    else {
        throw RemoteControlError.artifact("install provenance is invalid")
    }
    let provenance: RemoteProvenanceManifest
    do {
        provenance = try JSONDecoder().decode(RemoteProvenanceManifest.self, from: data)
    } catch {
        throw RemoteControlError.artifact("install provenance is invalid")
    }
    _ = try remoteValidateProvenance(provenance, rootURL: rootURL)
    return provenance
}

private func remoteValidateProvenance(_ provenance: RemoteProvenanceManifest, rootURL: URL) throws -> URL {
    guard provenance.schemaVersion == 1,
          provenance.runtimeRoot == rootURL.path,
          remoteIsRevision(provenance.revision),
          !provenance.entries.isEmpty
    else {
        throw RemoteControlError.artifact("provenance root or identity does not match this runtime")
    }
    let versionRoot = rootURL.appendingPathComponent("versions/\(provenance.revision)", isDirectory: true)
    var paths = Set<Data>()
    var portablePaths = Set<String>()
    for entry in provenance.entries {
        let url = URL(fileURLWithPath: entry.path).standardizedFileURL
        guard entry.path == url.path,
              entry.path.hasPrefix(versionRoot.path + "/"),
              paths.insert(Data(entry.path.utf8)).inserted,
              portablePaths.insert(remotePortablePathKey(entry.path)).inserted,
              remoteIsSHA256(entry.sha256)
        else {
            throw RemoteControlError.artifact("provenance entry is unsafe")
        }
    }
    return versionRoot
}

private func remoteVerifyInstalledArtifact(
    _ manifest: RemoteArtifactManifest,
    provenance: RemoteProvenanceManifest,
    versionRoot: URL
) throws {
    guard provenance.revision == manifest.revision,
          provenance.entries.count == manifest.files.count
    else {
        throw RemoteControlError.artifact("installed provenance does not match the artifact")
    }
    let installedProvenance = try remoteReadProvenance(
        at: versionRoot.appendingPathComponent("install-manifest.json"),
        rootURL: URL(fileURLWithPath: provenance.runtimeRoot, isDirectory: true)
    )
    guard installedProvenance == provenance else {
        throw RemoteControlError.artifact("installed provenance does not match the artifact")
    }
    for file in manifest.files {
        let path = versionRoot.appendingPathComponent(file.relativePath).path
        guard let entry = provenance.entries.first(where: { $0.path == path }), entry.sha256 == file.sha256 else {
            throw RemoteControlError.artifact("installed provenance does not match the artifact")
        }
    }
    try remoteVerifyRuntimePayload(
        manifest,
        rootURL: versionRoot,
        additionalExpectedFiles: [versionRoot.appendingPathComponent("install-manifest.json").path: 0o600]
    )
}

private func remoteVerifyStagedRuntime(
    rootURL: URL,
    manifest: RemoteArtifactManifest,
    provenance: RemoteProvenanceManifest,
    runtimeRootURL: URL
) throws {
    let stagedProvenanceURL = rootURL.appendingPathComponent("install-manifest.json")
    let stagedProvenance = try remoteReadProvenance(at: stagedProvenanceURL, rootURL: runtimeRootURL)
    guard stagedProvenance == provenance,
          provenance.revision == manifest.revision,
          provenance.entries.count == manifest.files.count
    else {
        throw RemoteControlError.artifact("staged provenance does not match the artifact")
    }
    try remoteVerifyRuntimePayload(
        manifest,
        rootURL: rootURL,
        additionalExpectedFiles: [stagedProvenanceURL.path: 0o600]
    )
}

private func remoteVerifyRuntimePayload(
    _ manifest: RemoteArtifactManifest,
    rootURL: URL,
    additionalExpectedFiles: [String: Int]
) throws {
    let root = try remotePhysicalDirectory(rootURL, label: "runtime version", domain: .artifact).physicalURL
    var expectedFiles = Set<String>()
    var expectedDirectories = Set<String>()
    for file in manifest.files {
        let url = try remoteRuntimeFileURL(rootURL: root, relativePath: file.relativePath)
        let metadata = try remoteRequireRegular(url, label: "runtime file", domain: .artifact)
        guard metadata.permissions == file.mode,
              RemoteArtifactVerifier.sha256(try remoteReadData(at: url, label: "runtime file")) == file.sha256
        else {
            throw RemoteControlError.artifact("installed runtime file does not match the artifact")
        }
        expectedFiles.insert(url.path)
        var directory = url.deletingLastPathComponent()
        while directory.path != root.path {
            expectedDirectories.insert(directory.path)
            directory.deleteLastPathComponent()
        }
    }
    for (path, mode) in additionalExpectedFiles {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        try remoteRequirePhysicalContainment(url, in: root, label: "runtime metadata", domain: .artifact)
        let metadata = try remoteRequireRegular(url, label: "runtime metadata", domain: .artifact)
        guard metadata.permissions == mode else {
            throw RemoteControlError.artifact("installed runtime metadata permissions do not match the artifact")
        }
        expectedFiles.insert(url.path)
    }
    try remoteVerifyExactTreeInventory(
        rootURL: root,
        expectedFiles: expectedFiles,
        expectedDirectories: expectedDirectories,
        label: "runtime version"
    )
}

private func remoteWriteCurrentRevision(_ revision: String, rootURL: URL) throws {
    let pointer = rootURL.appendingPathComponent("current")
    _ = try remoteReadCurrentRevisionIfPresent(pointer)
    try remoteWriteData(Data("\(revision)\n".utf8), to: pointer, label: "runtime pointer")
    _ = try remoteRequireRegular(pointer, label: "runtime pointer", domain: .artifact)
    try remoteSetPermissions(0o600, at: pointer, label: "runtime pointer", domain: .artifact)
}

private func remoteReadCurrentRevisionIfPresent(_ pointer: URL) throws -> String? {
    guard try remoteMetadata(at: pointer, label: "runtime pointer", domain: .artifact) != nil else {
        return nil
    }
    let metadata = try remoteRequireRegular(pointer, label: "runtime pointer", domain: .artifact)
    guard metadata.size <= 128 else {
        throw RemoteControlError.artifact("runtime pointer is corrupt")
    }
    let revision: String
    do {
        revision = try String(contentsOf: pointer, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        throw RemoteControlError.artifact("runtime pointer could not be read")
    }
    guard remoteIsRevision(revision) else {
        throw RemoteControlError.artifact("runtime pointer is corrupt")
    }
    return revision
}

private func remoteCheckpoint(
    _ checkpoint: RemoteInstallCheckpoint,
    callback: (RemoteInstallCheckpoint) throws -> Void
) throws {
    do {
        try callback(checkpoint)
    } catch {
        throw RemoteControlError.artifact("installation interrupted at \(checkpoint.rawValue)")
    }
}

private func remoteArtifactBuildCheckpoint(
    _ checkpoint: RemoteArtifactBuildCheckpoint,
    callback: (RemoteArtifactBuildCheckpoint) throws -> Void
) throws {
    do {
        try callback(checkpoint)
    } catch {
        throw RemoteControlError.artifact("artifact build interrupted at \(checkpoint.rawValue)")
    }
}

private func remoteRemoveItem(_ url: URL, label: String) throws {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        throw RemoteControlError.artifact("\(label) could not be removed")
    }
}

private func remoteWriteData(_ data: Data, to url: URL, label: String) throws {
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        throw RemoteControlError.artifact("\(label) could not be written")
    }
}

private func remoteReadData(at url: URL, label: String) throws -> Data {
    do {
        return try Data(contentsOf: url)
    } catch {
        throw RemoteControlError.artifact("\(label) could not be read")
    }
}
