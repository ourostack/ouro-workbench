import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class LaunchAgentLoginItemTests: XCTestCase {
    func testDefaultAppURLUsesBundleWhenRunningFromAppBundle() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let bundle = URL(fileURLWithPath: "/Users/example/Applications/Ouro Workbench.app", isDirectory: true)

        let appURL = LaunchAgentLoginItem.defaultAppURL(bundleURL: bundle, homeURL: home)

        XCTAssertEqual(appURL.path, bundle.path)
    }

    func testDefaultAppURLFallsBackToHomeApplicationsForDevelopmentRuns() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let bundle = URL(fileURLWithPath: "/tmp/.build/debug/OuroWorkbench")

        let appURL = LaunchAgentLoginItem.defaultAppURL(bundleURL: bundle, homeURL: home)

        XCTAssertEqual(appURL.path, "/Users/example/Applications/Ouro Workbench.app")
    }

    func testInstallWritesLaunchAgentPlist() throws {
        let root = try temporaryDirectory()
        let appURL = root.appendingPathComponent("Applications/Ouro Workbench.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let loginItem = LaunchAgentLoginItem(
            appURL: appURL,
            homeURL: root
        )

        XCTAssertEqual(loginItem.status(), .notInstalled)
        try loginItem.install()

        XCTAssertEqual(loginItem.status(), .enabled)
        let data = try Data(contentsOf: loginItem.plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["Label"] as? String, "com.ourostack.workbench.login")
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/usr/bin/open", appURL.path])
        XCTAssertEqual(
            plist["StandardErrorPath"] as? String,
            root.appendingPathComponent("Library/Logs/OuroWorkbench/login.err.log").path
        )

        try loginItem.uninstall()
        XCTAssertEqual(loginItem.status(), .notInstalled)
        try? FileManager.default.removeItem(at: root)
    }

    func testStatusReportsNeedsUpdateWhenPlistPointsAtDifferentApp() throws {
        let root = try temporaryDirectory()
        let appURL = root.appendingPathComponent("Applications/Ouro Workbench.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let loginItem = LaunchAgentLoginItem(
            appURL: appURL,
            homeURL: root
        )
        let stalePlist: [String: Any] = [
            "Label": "com.ourostack.workbench.login",
            "ProgramArguments": ["/usr/bin/open", "/tmp/Old Ouro Workbench.app"],
            "RunAtLoad": true
        ]
        try FileManager.default.createDirectory(
            at: loginItem.plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(fromPropertyList: stalePlist, format: .xml, options: 0)
        try data.write(to: loginItem.plistURL)

        XCTAssertEqual(loginItem.status(), .needsUpdate)

        try loginItem.install()
        XCTAssertEqual(loginItem.status(), .enabled)
        try? FileManager.default.removeItem(at: root)
    }

    func testInstallFailsWhenAppBundleIsMissing() throws {
        let root = try temporaryDirectory()
        let appURL = root.appendingPathComponent("Applications/Ouro Workbench.app", isDirectory: true)
        let loginItem = LaunchAgentLoginItem(
            appURL: appURL,
            homeURL: root
        )

        XCTAssertEqual(loginItem.status(), .appBundleMissing)
        XCTAssertThrowsError(try loginItem.install()) { error in
            XCTAssertEqual(error as? LaunchAgentLoginItemError, .appBundleMissing(appURL.path))
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testErrorDescriptionIncludesMissingBundlePath() {
        XCTAssertEqual(
            LaunchAgentLoginItemError.appBundleMissing("/Applications/Missing.app").errorDescription,
            "App bundle is missing at /Applications/Missing.app"
        )
    }

    func testUninstallIsNoOpWhenPlistIsAlreadyMissing() throws {
        let root = try temporaryDirectory()
        let appURL = root.appendingPathComponent("Applications/Ouro Workbench.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let loginItem = LaunchAgentLoginItem(appURL: appURL, homeURL: root)

        XCTAssertNoThrow(try loginItem.uninstall())
        XCTAssertEqual(loginItem.status(), .notInstalled)
        try? FileManager.default.removeItem(at: root)
    }

    func testMalformedPlistNeedsUpdate() throws {
        let root = try temporaryDirectory()
        let appURL = root.appendingPathComponent("Applications/Ouro Workbench.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let loginItem = LaunchAgentLoginItem(appURL: appURL, homeURL: root)
        try FileManager.default.createDirectory(
            at: loginItem.plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not a plist".utf8).write(to: loginItem.plistURL)

        XCTAssertEqual(loginItem.status(), .needsUpdate)
        try? FileManager.default.removeItem(at: root)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
