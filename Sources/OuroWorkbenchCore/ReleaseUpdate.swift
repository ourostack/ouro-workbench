import Foundation
import OuroAppShellCore

public typealias ReleaseUpdateStatus = OuroAppShellCore.ReleaseUpdateStatus
public typealias ReleaseUpdateAsset = OuroAppShellCore.ReleaseUpdateAsset
public typealias ReleaseUpdateSnapshot = OuroAppShellCore.ReleaseUpdateSnapshot
public typealias ReleaseUpdateError = OuroAppShellCore.ReleaseUpdateError
public typealias SemanticVersion = OuroAppShellCore.SemanticVersion
public typealias ReleaseVersionIdentity = OuroAppShellCore.ReleaseVersionIdentity

public struct ReleaseUpdateConfiguration: Equatable, Sendable {
    public var repository: String
    public var currentVersion: String
    public var currentBuild: String?
    public var releasesURL: URL

    public init(
        repository: String = WorkbenchRelease.repository,
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

    var appShellIdentity: AppShellIdentity {
        AppShellIdentity(
            appName: WorkbenchRelease.appName,
            bundleIdentifier: WorkbenchRelease.bundleIdentifier,
            repository: repository,
            version: currentVersion,
            build: currentBuild,
            userAgent: "OuroWorkbench/\(WorkbenchRelease.version)"
        )
    }

    var appShellConfiguration: OuroAppShellCore.ReleaseUpdateConfiguration {
        OuroAppShellCore.ReleaseUpdateConfiguration(
            identity: appShellIdentity,
            releasePolicy: .workbench(),
            releasesURL: releasesURL
        )
    }
}

public struct ReleaseUpdateChecker: Sendable {
    public var configuration: ReleaseUpdateConfiguration
    private let dataLoader: @Sendable (URL) async throws -> Data

    public init() {
        self.init(configuration: ReleaseUpdateConfiguration())
    }

    public init(configuration: ReleaseUpdateConfiguration) {
        self.init(configuration: configuration, dataLoader: Self.defaultDataLoader(url:))
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
            return try Self.snapshot(from: data, configuration: configuration)
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
                assetNamingPolicy: configuration.appShellConfiguration.assetNamingPolicy,
                detail: "Release update check failed: \(error.localizedDescription)"
            )
        }
    }

    public static func snapshot(
        from data: Data,
        currentVersion: String,
        currentBuild: String? = nil
    ) throws -> ReleaseUpdateSnapshot {
        try OuroAppShellCore.ReleaseUpdateChecker.snapshot(
            from: data,
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            assetNamingPolicy: .workbench(),
            includePrereleases: true
        )
    }

    public static func snapshot(
        from data: Data,
        configuration: ReleaseUpdateConfiguration
    ) throws -> ReleaseUpdateSnapshot {
        try OuroAppShellCore.ReleaseUpdateChecker.snapshot(
            from: data,
            configuration: configuration.appShellConfiguration
        )
    }

    public static func defaultDataLoader(url: URL) async throws -> Data {
        try await OuroAppShellCore.ReleaseUpdateChecker.defaultDataLoader(
            request: request(url: url)
        )
    }

    private static func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OuroWorkbench/\(WorkbenchRelease.version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        return request
    }
}
