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
    let paths = WorkbenchPaths(rootURL: workbenchLaunchDiagnostics.appSupportRoot!)
    let defaultsDomain = "com.ourostack.workbench.e2e"
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

if case let .dumpRecentSessions(scanHomeRoot) = workbenchLaunchDiagnostics.action {
    let scanner = RecentSessionScanner(homeURL: scanHomeRoot ?? FileManager.default.homeDirectoryForCurrentUser)
    let candidates = scanner.scan()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        let data = try encoder.encode(candidates)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        Darwin.exit(0)
    } catch {
        FileHandle.standardError.write(Data("Failed to encode recent sessions: \(error.localizedDescription)\n".utf8))
        Darwin.exit(1)
    }
}

if case let .writeE2EState(fixture, stateURL) = workbenchLaunchDiagnostics.action {
    do {
        switch fixture {
        case .sidebarSessionControls:
            let rootPath = FileManager.default.homeDirectoryForCurrentUser.path
            let project = WorkbenchProject(name: "Fixture Workspace", rootPath: rootPath)
            let entry = ProcessEntry(
                projectId: project.id,
                name: "Fixture Running Session",
                kind: .terminalAgent,
                agentKind: .openAICodex,
                executable: "/bin/zsh",
                arguments: ["-lc", "while true; do sleep 60; done"],
                workingDirectory: rootPath,
                trust: .trusted,
                autoResume: true,
                lastSummary: "Fixture running session"
            )
            let state = WorkspaceState(
                selectedProjectId: project.id,
                selectedEntryId: entry.id,
                projects: [project],
                processEntries: [entry]
            )
            try WorkbenchStore(stateURL: stateURL).save(state)
        }
        FileHandle.standardOutput.write(Data("wrote e2e state \(stateURL.path)\n".utf8))
        Darwin.exit(0)
    } catch {
        FileHandle.standardError.write(Data("Failed to write e2e state: \(error.localizedDescription)\n".utf8))
        Darwin.exit(1)
    }
}

OuroWorkbenchApp.main()
#endif
