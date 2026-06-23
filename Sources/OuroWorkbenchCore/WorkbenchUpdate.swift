import Foundation
import OuroAppShellCore

public typealias WorkbenchUpdateManifest = AppUpdateManifest
public typealias WorkbenchUpdatePlan = AppUpdatePlan
public typealias WorkbenchUpdatePlanError = AppUpdatePlanError
public typealias WorkbenchAutoUpdatePolicy = AutoUpdatePolicy

public enum WorkbenchUpdatePlanner {
    public static func plan(from snapshot: ReleaseUpdateSnapshot) -> Result<WorkbenchUpdatePlan, WorkbenchUpdatePlanError> {
        var workbenchSnapshot = snapshot
        workbenchSnapshot.assetNamingPolicy = .workbench(namePrefix: WorkbenchRelease.artifactNamePrefix)
        return AppUpdatePlanner.plan(from: workbenchSnapshot)
    }
}

public enum WorkbenchUpdateVerification {
    public typealias Failure = AppUpdateVerification.Failure

    public static func verify(
        manifest: WorkbenchUpdateManifest,
        downloadedArchiveName: String,
        downloadedSHA256: String,
        downloadedBytes: Int,
        expectedBundleIdentifier: String,
        currentVersion: String,
        currentBuild: String? = nil
    ) -> Failure? {
        AppUpdateVerification.verify(
            manifest: manifest,
            downloadedArchiveName: downloadedArchiveName,
            downloadedSHA256: downloadedSHA256,
            downloadedBytes: downloadedBytes,
            expectedBundleIdentifier: expectedBundleIdentifier,
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            compareBuilds: true
        )
    }
}
