import Foundation
import OuroAppShellUI
import OuroWorkbenchCore

public struct WorkbenchShellAboutPresentation: Equatable, Sendable {
    public static let subtitle = "Terminal-first orchestrator for autonomous Ouro agents."
    public static let iconSystemName = "infinity"

    public var buildHash: String

    public init(buildHash: String) {
        self.buildHash = buildHash
    }

    public var versionLine: String {
        "Version \(WorkbenchRelease.version) - Build \(buildHash)"
    }

    public var repositoryURL: URL {
        URL(string: "https://github.com/\(WorkbenchRelease.repository)")!
    }

    public var model: AppShellAboutModel {
        AppShellAboutModel(
            appName: WorkbenchRelease.appName,
            versionLine: versionLine,
            subtitle: Self.subtitle,
            repositoryURL: repositoryURL,
            iconSystemName: Self.iconSystemName
        )
    }
}

public struct WorkbenchShellUpdatePresentation: Equatable, Sendable {
    public var state: ReleaseUpdateViewState
    public var badgeText: String?
    public var promptRelease: String?
    public var releaseURL: URL?

    public init(
        state: ReleaseUpdateViewState,
        badgeText: String? = nil,
        promptRelease: String? = nil,
        releaseURL: URL? = nil
    ) {
        self.state = state
        self.badgeText = badgeText
        self.promptRelease = promptRelease
        self.releaseURL = releaseURL
    }
}

public enum WorkbenchShellUpdatePresenter {
    public static let channel = "Direct download"

    public static func presentation(
        snapshot: ReleaseUpdateSnapshot?,
        isChecking: Bool,
        isInstalling: Bool,
        installStatus: String?,
        installError: String?,
        stagedUpdateVersion: String?
    ) -> WorkbenchShellUpdatePresentation {
        let badgeText = updateBadgeText(snapshot: snapshot, stagedUpdateVersion: stagedUpdateVersion)
        let promptRelease = updatePromptRelease(snapshot: snapshot, stagedUpdateVersion: stagedUpdateVersion)
        let releaseURL = releaseURL(snapshot: snapshot)
        let state = ReleaseUpdateViewState(
            kind: kind(
                snapshot: snapshot,
                isChecking: isChecking,
                isInstalling: isInstalling,
                installError: installError,
                stagedUpdateVersion: stagedUpdateVersion
            ),
            statusLine: statusLine(snapshot: snapshot, isChecking: isChecking, isInstalling: isInstalling),
            metadata: metadata(snapshot: snapshot, stagedUpdateVersion: stagedUpdateVersion),
            detail: detail(snapshot: snapshot, isChecking: isChecking, isInstalling: isInstalling, installStatus: installStatus),
            warning: warning(snapshot: snapshot, isChecking: isChecking, installError: installError),
            canReviewUpdate: !isChecking && badgeText != nil,
            canInstallUpdate: canInstall(snapshot: snapshot, isChecking: isChecking, isInstalling: isInstalling, stagedUpdateVersion: stagedUpdateVersion),
            canOpenReleasePage: !isChecking && releaseURL != nil && snapshot?.status == .updateAvailable
        )
        return WorkbenchShellUpdatePresentation(
            state: state,
            badgeText: badgeText,
            promptRelease: promptRelease,
            releaseURL: releaseURL
        )
    }

    public static func releaseURL(snapshot: ReleaseUpdateSnapshot?) -> URL? {
        guard let htmlURL = snapshot?.htmlURL else {
            return nil
        }
        return URL(string: htmlURL)
    }

    private static func kind(
        snapshot: ReleaseUpdateSnapshot?,
        isChecking: Bool,
        isInstalling: Bool,
        installError: String?,
        stagedUpdateVersion: String?
    ) -> ReleaseUpdateStateKind {
        if isChecking { return .checking }
        if isInstalling { return .installing }
        if installError != nil { return .failed }
        if stagedUpdateVersion != nil { return .readyToRelaunch }
        guard let status = snapshot?.status else {
            return .notChecked
        }
        switch status {
        case .current: return .current
        case .updateAvailable: return .updateAvailable
        case .unavailable: return .unavailable
        }
    }

    private static func statusLine(
        snapshot: ReleaseUpdateSnapshot?,
        isChecking: Bool,
        isInstalling: Bool
    ) -> String {
        if isChecking {
            return "Checking for updates…"
        }
        if isInstalling {
            return "Installing update…"
        }
        guard let snapshot else {
            return "not checked"
        }
        return snapshot.detail
    }

    private static func metadata(
        snapshot: ReleaseUpdateSnapshot?,
        stagedUpdateVersion: String?
    ) -> [ReleaseUpdateMetadataItem] {
        var items: [ReleaseUpdateMetadataItem] = []
        if let latest = snapshot?.latestReleaseLabelForPrompt ?? stagedUpdateVersion {
            items.append(ReleaseUpdateMetadataItem(id: "latest", label: "Latest", value: latest))
        }
        if let current = snapshot?.currentReleaseLabelForPrompt {
            items.append(ReleaseUpdateMetadataItem(id: "current", label: "Current", value: current))
        }
        items.append(ReleaseUpdateMetadataItem(id: "channel", label: "Channel", value: channel))
        return items
    }

    private static func detail(
        snapshot: ReleaseUpdateSnapshot?,
        isChecking: Bool,
        isInstalling: Bool,
        installStatus: String?
    ) -> String? {
        if isChecking {
            return nil
        }
        if isInstalling {
            return installStatus
        }
        guard let snapshot, snapshot.status == .updateAvailable, snapshot.hasInstallableAssets else {
            return nil
        }
        return "Verified against the release's SHA-256 manifest and code signature before installing. Your running terminals keep running across the update."
    }

    private static func warning(
        snapshot: ReleaseUpdateSnapshot?,
        isChecking: Bool,
        installError: String?
    ) -> String? {
        if isChecking {
            return nil
        }
        if let installError {
            return installError
        }
        guard let snapshot, snapshot.status == .updateAvailable, !snapshot.hasInstallableAssets else {
            return nil
        }
        return "Release is published, but installable app assets were not found."
    }

    private static func canInstall(
        snapshot: ReleaseUpdateSnapshot?,
        isChecking: Bool,
        isInstalling: Bool,
        stagedUpdateVersion: String?
    ) -> Bool {
        if isChecking || isInstalling { return false }
        if stagedUpdateVersion != nil { return true }
        return snapshot?.status == .updateAvailable
            && snapshot?.hasInstallableAssets == true
    }

    private static func updateBadgeText(
        snapshot: ReleaseUpdateSnapshot?,
        stagedUpdateVersion: String?
    ) -> String? {
        if let stagedUpdateVersion {
            return "Update \(stagedUpdateVersion)"
        }
        guard let snapshot,
              snapshot.status == .updateAvailable,
              snapshot.hasInstallableAssets,
              let release = snapshot.latestReleaseLabelForPrompt else {
            return nil
        }
        return "Update \(release)"
    }

    private static func updatePromptRelease(
        snapshot: ReleaseUpdateSnapshot?,
        stagedUpdateVersion: String?
    ) -> String? {
        if let stagedUpdateVersion {
            return stagedUpdateVersion
        }
        guard let snapshot,
              snapshot.status == .updateAvailable,
              snapshot.hasInstallableAssets,
              let release = snapshot.latestReleaseLabelForPrompt else {
            return nil
        }
        return release
    }
}
