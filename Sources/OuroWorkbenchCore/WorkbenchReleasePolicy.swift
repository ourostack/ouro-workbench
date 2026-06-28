import OuroAppShellCore

public enum WorkbenchReleasePolicy {
    public static let assetNamingPolicy = ReleaseAssetNamingPolicy.buildMatchedArchiveAndManifest(
        namePrefix: WorkbenchRelease.artifactNamePrefix
    )

    public static let releaseUpdatePolicy = ReleaseUpdatePolicy.buildMatchedPrerelease(
        namePrefix: WorkbenchRelease.artifactNamePrefix
    )
}
