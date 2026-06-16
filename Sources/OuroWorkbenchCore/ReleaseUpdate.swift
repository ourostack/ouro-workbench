import Foundation

public enum ReleaseUpdateStatus: String, Codable, Equatable, Sendable {
    case current
    case updateAvailable
    case unavailable
}

public struct ReleaseUpdateAsset: Codable, Equatable, Sendable {
    public var name: String
    public var downloadURL: String
    public var size: Int

    public init(name: String, downloadURL: String, size: Int) {
        self.name = name
        self.downloadURL = downloadURL
        self.size = size
    }
}

public struct ReleaseUpdateSnapshot: Codable, Equatable, Sendable {
    public var status: ReleaseUpdateStatus
    public var currentVersion: String
    public var currentBuild: String?
    public var latestVersion: String?
    public var latestBuild: String?
    public var tagName: String?
    public var htmlURL: String?
    public var assets: [ReleaseUpdateAsset]
    public var detail: String

    public init(
        status: ReleaseUpdateStatus,
        currentVersion: String,
        currentBuild: String? = nil,
        latestVersion: String?,
        latestBuild: String? = nil,
        tagName: String?,
        htmlURL: String?,
        assets: [ReleaseUpdateAsset],
        detail: String
    ) {
        self.status = status
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.latestVersion = latestVersion
        self.latestBuild = latestBuild
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.assets = assets
        self.detail = detail
    }

    public var hasInstallableAssets: Bool {
        installableAssets.contains { $0.name.hasSuffix(".zip") }
            && installableAssets.contains { $0.name.hasSuffix(".manifest.json") }
    }

    public var installableAssets: [ReleaseUpdateAsset] {
        guard let latestVersion else {
            return []
        }
        return assets.filter {
            Self.isInstallableAssetName($0.name, version: latestVersion, build: latestBuild)
        }
    }

    public var currentReleaseLabel: String {
        ReleaseVersionIdentity(version: currentVersion, build: currentBuild).display
    }

    public var currentReleaseLabelForPrompt: String {
        ReleaseVersionIdentity(version: currentVersion, build: currentBuild).label
    }

    public var latestReleaseLabel: String? {
        guard let latestVersion else { return nil }
        return ReleaseVersionIdentity(version: latestVersion, build: latestBuild).display
    }

    public var latestReleaseLabelForPrompt: String? {
        guard let latestVersion else { return nil }
        return ReleaseVersionIdentity(version: latestVersion, build: latestBuild).label
    }

    private static func isInstallableAssetName(_ name: String, version: String, build: String?) -> Bool {
        let prefix = "OuroWorkbench-\(version)-build."
        guard name.hasPrefix(prefix) else {
            return false
        }
        if let build {
            guard name.hasPrefix("\(prefix)\(build)-") else {
                return false
            }
        }
        return name.hasSuffix(".zip") || name.hasSuffix(".manifest.json")
    }
}

public struct ReleaseUpdateConfiguration: Equatable, Sendable {
    public var repository: String
    public var currentVersion: String
    public var currentBuild: String?
    public var releasesURL: URL

    public init(
        repository: String = "ourostack/ouro-workbench",
        currentVersion: String = WorkbenchRelease.version,
        currentBuild: String? = ReleaseUpdateConfiguration.defaultCurrentBuild(),
        releasesURL: URL? = nil
    ) {
        self.repository = repository
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.releasesURL = releasesURL ?? URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=10")!
    }

    public static func defaultCurrentBuild() -> String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }
}

public struct ReleaseUpdateChecker: Sendable {
    public var configuration: ReleaseUpdateConfiguration
    private let dataLoader: @Sendable (URL) async throws -> Data

    public init() {
        self.init(configuration: ReleaseUpdateConfiguration())
    }

    public init(configuration: ReleaseUpdateConfiguration) {
        self.configuration = configuration
        self.dataLoader = Self.defaultDataLoader
    }

    public init(
        configuration: ReleaseUpdateConfiguration = ReleaseUpdateConfiguration(),
        dataLoader: @escaping @Sendable (URL) async throws -> Data
    ) {
        self.configuration = configuration
        self.dataLoader = dataLoader
    }

    public func check() async -> ReleaseUpdateSnapshot {
        do {
            let data = try await dataLoader(configuration.releasesURL)
            return try Self.snapshot(
                from: data,
                currentVersion: configuration.currentVersion,
                currentBuild: configuration.currentBuild
            )
        } catch {
            return ReleaseUpdateSnapshot(
                status: .unavailable,
                currentVersion: configuration.currentVersion,
                currentBuild: configuration.currentBuild,
                latestVersion: nil,
                latestBuild: nil,
                tagName: nil,
                htmlURL: nil,
                assets: [],
                detail: "Release update check failed: \(error.localizedDescription)"
            )
        }
    }

    public static func snapshot(from data: Data, currentVersion: String, currentBuild: String? = nil) throws -> ReleaseUpdateSnapshot {
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        guard let latest = releases.first(where: { !$0.draft }) else {
            return ReleaseUpdateSnapshot(
                status: .unavailable,
                currentVersion: currentVersion,
                currentBuild: currentBuild,
                latestVersion: nil,
                latestBuild: nil,
                tagName: nil,
                htmlURL: nil,
                assets: [],
                detail: "No published release found."
            )
        }

        let latestVersion = Self.version(fromTag: latest.tagName)
        let latestBuild = Self.latestBuild(from: latest.assets, version: latestVersion)
        let status = Self.status(
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            latestVersion: latestVersion,
            latestBuild: latestBuild
        )
        let assets = latest.assets.map {
            ReleaseUpdateAsset(name: $0.name, downloadURL: $0.browserDownloadURL, size: $0.size)
        }
        let detail: String
        switch status {
        case .updateAvailable:
            detail = "\(ReleaseVersionIdentity(version: latestVersion, build: latestBuild).display) is available."
        case .current:
            detail = "\(ReleaseVersionIdentity(version: currentVersion, build: currentBuild).display) is current."
        case .unavailable:
            detail = "Latest release \(latest.tagName) could not be compared to \(currentVersion)."
        }

        return ReleaseUpdateSnapshot(
            status: status,
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            latestVersion: latestVersion,
            latestBuild: latestBuild,
            tagName: latest.tagName,
            htmlURL: latest.htmlURL,
            assets: assets,
            detail: detail
        )
    }

    public static func defaultDataLoader(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OuroWorkbench/\(WorkbenchRelease.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ReleaseUpdateError.badResponse
        }
        return data
    }

    private static func status(
        currentVersion: String,
        currentBuild: String?,
        latestVersion: String,
        latestBuild: String?
    ) -> ReleaseUpdateStatus {
        let current = ReleaseVersionIdentity(version: currentVersion, build: currentBuild)
        let latest = ReleaseVersionIdentity(version: latestVersion, build: latestBuild)
        guard let isNewer = latest.isNewer(than: current) else {
            return .unavailable
        }
        return isNewer ? .updateAvailable : .current
    }

    private static func version(fromTag tagName: String) -> String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }

    private static func latestBuild(from assets: [GitHubReleaseAsset], version: String) -> String? {
        let builds = assets.compactMap { asset -> Int? in
            guard asset.name.hasSuffix(".zip") || asset.name.hasSuffix(".manifest.json") else {
                return nil
            }
            return buildNumber(fromAssetName: asset.name, version: version)
        }
        return builds.max().map(String.init)
    }

    private static func buildNumber(fromAssetName name: String, version: String) -> Int? {
        let marker = "OuroWorkbench-\(version)-build."
        guard name.hasPrefix(marker) else {
            return nil
        }
        let tail = name.dropFirst(marker.count)
        let digits = tail.prefix { $0.isNumber }
        guard !digits.isEmpty else {
            return nil
        }
        return Int(digits)
    }
}

public enum ReleaseUpdateError: Error, Equatable, LocalizedError, Sendable {
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .badResponse:
            return "GitHub Releases returned an unsuccessful response."
        }
    }
}

private struct GitHubRelease: Decodable {
    var tagName: String
    var htmlURL: String
    var draft: Bool
    var prerelease: Bool
    var assets: [GitHubReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    var name: String
    var browserDownloadURL: String
    var size: Int

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}

struct SemanticVersion: Comparable {
    var major: Int
    var minor: Int
    var patch: Int

    init?(_ value: String) {
        let core = value.split(separator: "-", maxSplits: 1).first.map(String.init) ?? value
        let parts = core.split(separator: ".")
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2])
        else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        return lhs.patch < rhs.patch
    }
}

struct ReleaseVersionIdentity: Equatable, Sendable {
    var version: String
    var build: String?

    var display: String {
        "Version \(label)"
    }

    var label: String {
        guard let build, !build.isEmpty else {
            return version
        }
        return "\(version) (build \(build))"
    }

    func isNewer(than current: ReleaseVersionIdentity) -> Bool? {
        guard let candidateVersion = SemanticVersion(version),
              let currentVersion = SemanticVersion(current.version) else {
            return nil
        }
        if candidateVersion != currentVersion {
            return candidateVersion > currentVersion
        }
        guard let candidateBuild = numericBuild,
              let currentBuild = current.numericBuild else {
            return false
        }
        return candidateBuild > currentBuild
    }

    private var numericBuild: Int? {
        guard let build else {
            return nil
        }
        return Int(build)
    }
}
