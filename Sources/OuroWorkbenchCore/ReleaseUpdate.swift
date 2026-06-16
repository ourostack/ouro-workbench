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
    public var latestVersion: String?
    public var tagName: String?
    public var htmlURL: String?
    public var assets: [ReleaseUpdateAsset]
    public var detail: String

    public init(
        status: ReleaseUpdateStatus,
        currentVersion: String,
        latestVersion: String?,
        tagName: String?,
        htmlURL: String?,
        assets: [ReleaseUpdateAsset],
        detail: String
    ) {
        self.status = status
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.assets = assets
        self.detail = detail
    }

    public var hasInstallableAssets: Bool {
        assets.contains { $0.name.hasSuffix(".zip") }
            && assets.contains { $0.name.hasSuffix(".manifest.json") }
    }
}

public struct ReleaseUpdateConfiguration: Equatable, Sendable {
    public var repository: String
    public var currentVersion: String
    public var releasesURL: URL

    public init(
        repository: String = "ourostack/ouro-workbench",
        currentVersion: String = WorkbenchRelease.version,
        releasesURL: URL? = nil
    ) {
        self.repository = repository
        self.currentVersion = currentVersion
        self.releasesURL = releasesURL ?? URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=10")!
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
                currentVersion: configuration.currentVersion
            )
        } catch {
            return ReleaseUpdateSnapshot(
                status: .unavailable,
                currentVersion: configuration.currentVersion,
                latestVersion: nil,
                tagName: nil,
                htmlURL: nil,
                assets: [],
                detail: "Release update check failed: \(error.localizedDescription)"
            )
        }
    }

    public static func snapshot(from data: Data, currentVersion: String) throws -> ReleaseUpdateSnapshot {
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        guard let latest = releases.first(where: { !$0.draft }) else {
            return ReleaseUpdateSnapshot(
                status: .unavailable,
                currentVersion: currentVersion,
                latestVersion: nil,
                tagName: nil,
                htmlURL: nil,
                assets: [],
                detail: "No published release found."
            )
        }

        let latestVersion = Self.version(fromTag: latest.tagName)
        let status = Self.status(currentVersion: currentVersion, latestVersion: latestVersion)
        let assets = latest.assets.map {
            ReleaseUpdateAsset(name: $0.name, downloadURL: $0.browserDownloadURL, size: $0.size)
        }
        let detail: String
        switch status {
        case .updateAvailable:
            detail = "Version \(latestVersion) is available."
        case .current:
            detail = "Version \(currentVersion) is current."
        case .unavailable:
            detail = "Latest release \(latest.tagName) could not be compared to \(currentVersion)."
        }

        return ReleaseUpdateSnapshot(
            status: status,
            currentVersion: currentVersion,
            latestVersion: latestVersion,
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

    private static func status(currentVersion: String, latestVersion: String) -> ReleaseUpdateStatus {
        guard let current = SemanticVersion(currentVersion), let latest = SemanticVersion(latestVersion) else {
            return .unavailable
        }
        return latest > current ? .updateAvailable : .current
    }

    private static func version(fromTag tagName: String) -> String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
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
