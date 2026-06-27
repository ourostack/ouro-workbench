#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// Coverage-tightening (Class 5) — `LoginItemController` (residual-baseline.md K1 #2,
/// carved as the "SMAppService login-item" — but `LaunchAgentLoginItem` is actually
/// FileManager-based plist I/O, NOT SMAppService). The controller's LOGIC (status →
/// statusLine mapping, register/unregister flows, the `lastError` error-formatting path,
/// the `isUpdating` flag) is plain `@MainActor` code over an injectable `LaunchAgentLoginItem`.
///
/// The new `init(loginItem:)` seam lets a test inject an item rooted at a TEMP home, so every
/// state transition + error path is driven HERMETICALLY: install()/uninstall() write/remove a
/// real plist in temp — NO actual login-item syscall. Mutation-verified.
@MainActor
final class LoginItemControllerTests: XCTestCase {

    /// A throwaway temp root; a real `appURL` file inside it so `status()` doesn't short-circuit
    /// to `.appBundleMissing` unless we want it to.
    private func tempRoot() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("loginitem-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A `LaunchAgentLoginItem` whose home is `root` and whose appURL is a REAL file (so the
    /// bundle-missing guard passes); `appExists == false` points appURL at a non-existent path.
    private func item(root: URL, appExists: Bool = true) -> LaunchAgentLoginItem {
        let appURL = root.appendingPathComponent("Ouro Workbench.app", isDirectory: true)
        if appExists {
            try? FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        }
        return LaunchAgentLoginItem(appURL: appURL, homeURL: root)
    }

    // MARK: - statusLine mapping (all four LaunchAgentLoginItemStatus cases)

    func testStatusLine_appBundleMissing() {
        let root = tempRoot()
        let c = LoginItemController(loginItem: item(root: root, appExists: false))
        XCTAssertEqual(c.status, .appBundleMissing, "no app bundle on disk")
        XCTAssertEqual(c.statusLine, "install app first")
        XCTAssertFalse(c.isEnabled, "appBundleMissing is not enabled")
    }

    func testStatusLine_notInstalled() {
        let root = tempRoot()
        let c = LoginItemController(loginItem: item(root: root))   // app exists, no plist
        XCTAssertEqual(c.status, .notInstalled, "app exists but no LaunchAgents plist")
        XCTAssertEqual(c.statusLine, "not registered")
        XCTAssertFalse(c.isEnabled)
    }

    func testStatusLine_enabled_afterInstall() throws {
        let root = tempRoot()
        let c = LoginItemController(loginItem: item(root: root))
        c.setEnabled(true)   // installs the matching plist
        XCTAssertEqual(c.status, .enabled, "install wrote a matching plist → enabled")
        XCTAssertEqual(c.statusLine, "enabled")
        XCTAssertTrue(c.isEnabled, "enabled status → isEnabled true")
    }

    func testStatusLine_needsUpdate_whenPlistMismatches() throws {
        let root = tempRoot()
        let li = item(root: root)
        // Write a plist that does NOT match the current app (stale ProgramArguments).
        try FileManager.default.createDirectory(
            at: li.plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stale: [String: Any] = ["Label": li.label, "ProgramArguments": ["/usr/bin/open", "/old/path.app"]]
        let data = try PropertyListSerialization.data(fromPropertyList: stale, format: .xml, options: 0)
        try data.write(to: li.plistURL)
        let c = LoginItemController(loginItem: li)
        XCTAssertEqual(c.status, .needsUpdate, "a mismatching plist → needsUpdate")
        XCTAssertEqual(c.statusLine, "update needed")
    }

    // MARK: - setEnabled register / unregister flows + isUpdating

    func testSetEnabled_true_installsPlist_thenFalse_removesIt() throws {
        let root = tempRoot()
        let li = item(root: root)
        let c = LoginItemController(loginItem: li)
        XCTAssertEqual(c.status, .notInstalled, "precondition: not installed")

        c.setEnabled(true)
        XCTAssertEqual(c.status, .enabled, "setEnabled(true) → install → enabled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: li.plistURL.path), "the plist landed")
        XCTAssertFalse(c.isUpdating, "isUpdating is reset by the defer")
        XCTAssertNil(c.lastError, "a clean install clears lastError")

        c.setEnabled(false)
        XCTAssertEqual(c.status, .notInstalled, "setEnabled(false) → uninstall → not installed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: li.plistURL.path), "the plist was removed")
    }

    /// `registerIfNeeded` guard: setEnabled(true) on an ALREADY-enabled controller is a no-op
    /// install (the `guard status != .enabled else { return }` TRUE/return arm).
    func testSetEnabled_true_whenAlreadyEnabled_isNoOp() throws {
        let root = tempRoot()
        let c = LoginItemController(loginItem: item(root: root))
        c.setEnabled(true)
        XCTAssertEqual(c.status, .enabled, "precondition: enabled")
        c.setEnabled(true)   // guard `status != .enabled` is false → early return (no re-install)
        XCTAssertEqual(c.status, .enabled, "still enabled, no error")
        XCTAssertNil(c.lastError)
    }

    /// `unregisterIfNeeded` switch: setEnabled(false) when NOT installed → the
    /// `.notInstalled` case returns without an uninstall (no error).
    func testSetEnabled_false_whenNotInstalled_isNoOp() {
        let root = tempRoot()
        let c = LoginItemController(loginItem: item(root: root))
        XCTAssertEqual(c.status, .notInstalled, "precondition: not installed")
        c.setEnabled(false)
        XCTAssertEqual(c.status, .notInstalled, "no-op, no error")
        XCTAssertNil(c.lastError)
    }

    // MARK: - lastError formatting (the catch path — residual-baseline :10600)

    func testSetEnabled_true_appBundleMissing_setsLastError() {
        let root = tempRoot()
        // App bundle does NOT exist → install() throws appBundleMissing → the catch arm formats
        // lastError. (status is .appBundleMissing, so registerIfNeeded's guard passes and install
        // is attempted, which throws.)
        let c = LoginItemController(loginItem: item(root: root, appExists: false))
        XCTAssertEqual(c.status, .appBundleMissing)
        c.setEnabled(true)
        XCTAssertNotNil(c.lastError, "install throwing → lastError is set (the catch arm)")
        XCTAssertTrue(c.lastError?.hasPrefix("Open at Login update failed:") == true,
                      "the lastError carries the standard prefix: \(c.lastError ?? "nil")")
    }

    // MARK: - refresh re-reads the status

    func testRefresh_reReadsStatus() throws {
        let root = tempRoot()
        let li = item(root: root)
        let c = LoginItemController(loginItem: li)
        XCTAssertEqual(c.status, .notInstalled, "precondition")
        // Install the plist out-of-band, then refresh → status flips to enabled.
        try li.install()
        c.refresh()
        XCTAssertEqual(c.status, .enabled, "refresh re-reads loginItem.status()")
    }
}
#endif
