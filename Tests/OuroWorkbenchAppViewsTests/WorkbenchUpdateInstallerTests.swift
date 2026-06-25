#if os(macOS)
import Foundation
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

final class WorkbenchUpdateInstallerTests: XCTestCase {
    func testInstallScriptSwapsTempBundleAndWritesSuccessStatus() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let stagedApp = stagingRoot.appendingPathComponent("Ouro Workbench.app", isDirectory: true)
        let destination = root.appendingPathComponent("Installed.app", isDirectory: true)
        let statusURL = root.appendingPathComponent("status/install.status")
        try writeFile(stagedApp.appendingPathComponent("new.txt"), contents: "new")
        try writeFile(destination.appendingPathComponent("old.txt"), contents: "old")

        let script = WorkbenchUpdateInstaller.installScript(
            staged: WorkbenchUpdateStager.Staged(appURL: stagedApp, stagingRoot: stagingRoot, version: "0.1.200", build: "300"),
            destinationBundle: destination,
            relaunch: false,
            processIdentifier: 999_999,
            statusURL: statusURL,
            launchServicesRegisterPath: "/usr/bin/true"
        )

        let result = try runShell(script)

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("new.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("old.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
        let status = try String(contentsOf: statusURL, encoding: .utf8)
        XCTAssertTrue(status.contains("state=succeeded"))
        XCTAssertTrue(status.contains("release=0.1.200 (build 300)"))
        XCTAssertTrue(status.contains("destination=\(destination.path)"))
    }

    func testInstallScriptLeavesDestinationAndWritesFailureWhenCopyFails() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let missingStagedApp = stagingRoot.appendingPathComponent("Missing.app", isDirectory: true)
        let destination = root.appendingPathComponent("Installed.app", isDirectory: true)
        let statusURL = root.appendingPathComponent("status/install.status")
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try writeFile(destination.appendingPathComponent("old.txt"), contents: "old")

        let script = WorkbenchUpdateInstaller.installScript(
            staged: WorkbenchUpdateStager.Staged(appURL: missingStagedApp, stagingRoot: stagingRoot, version: "0.1.200", build: "300"),
            destinationBundle: destination,
            relaunch: false,
            processIdentifier: 999_999,
            statusURL: statusURL,
            launchServicesRegisterPath: "/usr/bin/true"
        )

        let result = try runShell(script)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("old.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("new.txt").path))
        let status = try String(contentsOf: statusURL, encoding: .utf8)
        XCTAssertTrue(status.contains("state=failed"))
        XCTAssertTrue(status.contains("detail=ditto failed"))
    }

    func testInstallScriptFailsWhenDestinationCannotMoveAside() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let stagedApp = stagingRoot.appendingPathComponent("Ouro Workbench.app", isDirectory: true)
        let destination = root.appendingPathComponent("Installed.app", isDirectory: true)
        let statusURL = root.appendingPathComponent("status/install.status")
        let fakeMove = root.appendingPathComponent("mv")
        try writeFile(stagedApp.appendingPathComponent("new.txt"), contents: "new")
        try writeFile(destination.appendingPathComponent("old.txt"), contents: "old")
        try writeExecutable(
            fakeMove,
            contents: """
            #!/bin/sh
            case "$2" in
              *.update-bak) exit 1 ;;
              *) exec /bin/mv "$@" ;;
            esac
            """
        )

        let script = WorkbenchUpdateInstaller.installScript(
            staged: WorkbenchUpdateStager.Staged(appURL: stagedApp, stagingRoot: stagingRoot, version: "0.1.200", build: "300"),
            destinationBundle: destination,
            relaunch: false,
            processIdentifier: 999_999,
            statusURL: statusURL,
            movePath: fakeMove.path,
            launchServicesRegisterPath: "/usr/bin/true"
        )

        let result = try runShell(script)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("old.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Ouro Workbench.app/new.txt").path))
        let status = try String(contentsOf: statusURL, encoding: .utf8)
        XCTAssertTrue(status.contains("state=failed"))
        XCTAssertTrue(status.contains("detail=could not move existing app aside"))
    }

    func testApplyAndRelaunchReportsHelperLaunchFailure() throws {
        struct LaunchFailure: LocalizedError {
            var errorDescription: String? { "helper denied" }
        }

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stagedApp = root.appendingPathComponent("Ouro Workbench.app", isDirectory: true)
        let destination = root.appendingPathComponent("Installed.app", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedApp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let result = WorkbenchUpdateInstaller.applyAndRelaunch(
            staged: WorkbenchUpdateStager.Staged(appURL: stagedApp, stagingRoot: root, version: "0.1.200", build: "300"),
            destinationBundle: destination,
            relaunch: false,
            helperLauncher: { _, _ in throw LaunchFailure() }
        )

        XCTAssertEqual(result, .failedToLaunch("helper denied"))
    }

    private struct ShellResult {
        var status: Int32
        var stderr: String
    }

    private func runShell(_ script: String) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ShellResult(
            status: process.terminationStatus,
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("workbench-update-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFile(_ url: URL, contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeExecutable(_ url: URL, contents: String) throws {
        try writeFile(url, contents: contents)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
#endif
