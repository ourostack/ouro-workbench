#if os(macOS)
import Darwin
import Foundation
import OuroWorkbenchCore
import SwiftUI

private func parseLaunchDiagnostics() -> WorkbenchLaunchDiagnostics {
    do {
        return try WorkbenchLaunchDiagnostics.parse(CommandLine.arguments)
    } catch {
        FileHandle.standardError.write(Data("Invalid Workbench launch arguments: \(error.localizedDescription)\n".utf8))
        Darwin.exit(2)
    }
}

let workbenchLaunchDiagnostics = parseLaunchDiagnostics()

if CommandLine.arguments.contains("--smoke-launch") {
    let swiftTermBundleURL = Bundle.main.resourceURL?
        .appendingPathComponent("SwiftTerm_SwiftTerm.bundle", isDirectory: true)
    guard let swiftTermBundleURL, FileManager.default.fileExists(atPath: swiftTermBundleURL.path) else {
        let resourcePath = Bundle.main.resourceURL?.path ?? "<missing resource directory>"
        FileHandle.standardError.write(Data("Missing SwiftTerm resource bundle under \(resourcePath)\n".utf8))
        Darwin.exit(1)
    }

    FileHandle.standardOutput.write(Data("OuroWorkbench smoke launch ok\n".utf8))
    Darwin.exit(0)
}

if workbenchLaunchDiagnostics.action == .factoryResetForE2E {
    let paths = WorkbenchPaths(rootURL: workbenchLaunchDiagnostics.appSupportRoot ?? WorkbenchPaths.defaultPaths().rootURL)
    let defaultsDomain = workbenchLaunchDiagnostics.appSupportRoot == nil
        ? WorkbenchRelease.bundleIdentifier
        : "com.ourostack.workbench.e2e"
    let defaults = UserDefaults(suiteName: defaultsDomain) ?? .standard
    let result = WorkbenchFactoryReset.resetToFactoryDefaults(
        stateURL: paths.stateURL,
        defaults: defaults,
        defaultsDomain: defaultsDomain,
        timestamp: Date()
    )
    defaults.synchronize()
    let backup = result.backupURL?.path ?? "<none>"
    FileHandle.standardOutput.write(Data("factory reset ok\nbackup=\(backup)\nmarker=\(result.setupMarkerURL.path)\n".utf8))
    Darwin.exit(0)
}

OuroWorkbenchApp.main()
#endif
