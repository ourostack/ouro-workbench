import Foundation
import OuroAppShellContract
import OuroWorkbenchCore

public enum WorkbenchShellContract {
    public static let requiredSurfaces: [AppShellSurface] = [
        .appIdentity,
        .releaseUpdates,
        .about,
        .keyboardShortcuts,
        .settings,
        .windowChrome
    ]
    public static let releaseInstallCapability: ReleaseInstallCapability = .directInstallAndRelaunch

    public static var contract: OuroAppShellContract {
        OuroAppShellContract(
            identity: identity,
            requiredSurfaces: requiredSurfaces,
            releaseUpdates: OuroAppShellReleaseUpdateContract(
                policy: WorkbenchReleasePolicy.releaseUpdatePolicy,
                installCapability: releaseInstallCapability,
                supportsReleasePage: true
            ),
            about: OuroAppShellAboutContract(
                subtitle: WorkbenchShellAboutPresentation.subtitle,
                repositoryURL: identity.repositoryURL
            ),
            commandReference: OuroAppShellCommandReferenceContract(
                title: WorkbenchShellCommandReference.title,
                commandCount: WorkbenchShellCommandReference.items.count,
                sections: WorkbenchShellCommandReference.sectionOrder,
                entryPoint: "Ouro Workbench > Keyboard Shortcuts"
            ),
            commandManifest: WorkbenchShellCommandReference.manifest,
            utilityWindows: [
                .init(id: "about", surface: .about, title: "About Ouro Workbench"),
                .init(id: "keyboard-shortcuts", surface: .keyboardShortcuts, title: WorkbenchShellCommandReference.title),
                .init(id: "settings", surface: .settings, title: "Settings")
            ],
            settings: OuroAppShellSettingsContract(
                entryPoint: "Ouro Workbench > Settings (Command ,)",
                appOwnedSections: [
                    "Terminal",
                    "Appearance",
                    "Workbench Chrome",
                    "Startup",
                    "Software Updates",
                    "Boss",
                    "Advanced"
                ]
            )
        )
    }

    public static var identity: AppShellIdentity {
        AppShellIdentity(
            appName: WorkbenchRelease.appName,
            bundleIdentifier: WorkbenchRelease.bundleIdentifier,
            repository: WorkbenchRelease.repository,
            version: WorkbenchRelease.version,
            userAgent: WorkbenchRelease.userAgent(),
            distributionChannel: .directDownload
        )
    }
}

private extension AppShellIdentity {
    var repositoryURL: URL {
        URL(string: "https://github.com/\(repository)")!
    }
}
