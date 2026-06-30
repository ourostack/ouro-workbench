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
                sharedSections: [
                    .updates(entryPoint: "Ouro Workbench > Settings > Software Updates"),
                    .privacy(entryPoint: "Ouro Workbench > Support Diagnostics"),
                    .about(entryPoint: "Ouro Workbench > About Ouro Workbench"),
                    .keyboardShortcuts(entryPoint: "Ouro Workbench > Keyboard Shortcuts")
                ],
                appOwnedSections: [
                    "Terminal",
                    "Appearance",
                    "Workbench Chrome",
                    "Startup",
                    "Boss",
                    "Advanced"
                ]
            ),
            privacyDiagnostics: OuroAppShellPrivacyDiagnosticsContract(
                telemetryConsentEntryPoint: "Ouro Workbench > Settings",
                privacyDocumentURL: URL(string: "https://github.com/ourostack/ouro-workbench/blob/main/README.md#support-diagnostics")!,
                diagnosticsExportDisclosure: "Support Diagnostics creates a local zip with system, app-bundle, login-item, runtime, and workspace summary evidence.",
                supportBundleContents: [
                    "system evidence",
                    "app bundle evidence",
                    "login item evidence",
                    "runtime evidence",
                    "workspace summary evidence"
                ],
                redactionGuarantees: [
                    "no transcript contents by default",
                    "no raw workspace state by default"
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
