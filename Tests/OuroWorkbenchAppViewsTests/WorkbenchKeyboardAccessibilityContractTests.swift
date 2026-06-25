#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

@MainActor
final class WorkbenchKeyboardAccessibilityContractTests: XCTestCase {
    func testKeyboardAccessibilityContractPassesForCurrentRepo() throws {
        let report = WorkbenchKeyboardAccessibilityContract.evaluate(packageRoot: repoRoot())
        XCTAssertTrue(
            report.failures.isEmpty,
            "keyboard/a11y contract failures:\n\(report.failures.joined(separator: "\n"))"
        )
    }

    func testCriticalPowerUserShortcutsAreNativeMenuBacked() {
        let byCommand = Dictionary(uniqueKeysWithValues: WorkbenchNativeMenuCatalog.allShortcuts.map {
            ($0.command, $0)
        })
        XCTAssertEqual(byCommand[.stopSelected]?.guideKeys, "⌘.")
        XCTAssertEqual(byCommand[.toggleSidebar]?.guideKeys, "⌃⌘B")
        XCTAssertEqual(byCommand[.shortcutsHelp]?.guideKeys, "⌘/")
        XCTAssertEqual(byCommand[.reportBug]?.guideKeys, "⇧⌘B")
    }

    func testScopedLaunchShortcutIsDocumentedButNotClaimedAsNativeMenuBacked() {
        XCTAssertTrue(WorkbenchScopedShortcutCatalog.allShortcuts.contains {
            $0.guideKeys == "⌘↩" && $0.scope == .selectedTerminalDetail
        })
        XCTAssertFalse(WorkbenchNativeMenuCatalog.allShortcuts.contains {
            $0.guideKeys == "⌘↩"
        })
    }

    func testNativeMenuChordsAreUnique() {
        let chords = WorkbenchNativeMenuCatalog.allShortcuts.map(\.chord)
        XCTAssertEqual(chords.count, Set(chords).count, "native menu shortcuts must not collide")
    }

    func testCIAndPreflightRunKeyboardAccessibilityContractProbe() throws {
        let root = repoRoot()
        let ci = try String(
            contentsOf: root
                .appendingPathComponent(".github", isDirectory: true)
                .appendingPathComponent("workflows", isDirectory: true)
                .appendingPathComponent("ci.yml"),
            encoding: .utf8
        )
        let preflight = try String(
            contentsOf: root
                .appendingPathComponent("scripts", isDirectory: true)
                .appendingPathComponent("preflight.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(ci.contains("--keyboarda11ycontract"))
        XCTAssertTrue(preflight.contains("--keyboarda11ycontract"))
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
#endif
