import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchFactoryResetTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-factory-reset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testBacksUpStateFileToTimestampedSiblingAndClearsAllPreferences() throws {
        let fm = FileManager.default
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let stateURL = dir.appendingPathComponent("workspace-state.json")
        let payload = #"{"groups":[{"name":"This Mac"}]}"#
        try Data(payload.utf8).write(to: stateURL)

        // A real, isolated defaults domain standing in for the app's — seeded
        // with the kinds of prefs a factory reset must clear (font, theme,
        // onboarding flag), not just the onboarding flag.
        let domain = "com.ourostack.workbench.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(15.0, forKey: "ouro.workbench.terminalFontSize")
        defaults.set("dark", forKey: "ouro.workbench.theme")
        defaults.set(true, forKey: "ouro.workbench.onboardingAutoPresented")
        XCTAssertEqual(defaults.double(forKey: "ouro.workbench.terminalFontSize"), 15.0)

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let backup = WorkbenchFactoryReset.wipeData(
            stateURL: stateURL,
            defaults: defaults,
            defaultsDomain: domain,
            timestamp: timestamp
        )

        // State moved aside to the timestamped backup and removed from its slot.
        let expectedBackup = dir.appendingPathComponent("workspace-state.1700000000.bak.json")
        XCTAssertEqual(backup, expectedBackup)
        XCTAssertFalse(fm.fileExists(atPath: stateURL.path), "state file should be gone")
        XCTAssertTrue(fm.fileExists(atPath: expectedBackup.path), "backup should exist")
        XCTAssertEqual(try String(contentsOf: expectedBackup), payload, "backup is the original, intact")

        // EVERY preference cleared — a true factory state, not just onboarding.
        XCTAssertEqual(defaults.double(forKey: "ouro.workbench.terminalFontSize"), 0.0)
        XCTAssertNil(defaults.string(forKey: "ouro.workbench.theme"))
        XCTAssertFalse(defaults.bool(forKey: "ouro.workbench.onboardingAutoPresented"))
    }

    func testNoStateFileStillClearsPreferencesAndReturnsNil() {
        let domain = "com.ourostack.workbench.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "ouro.workbench.onboardingAutoPresented")

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString).json")
        let backup = WorkbenchFactoryReset.wipeData(
            stateURL: missing,
            defaults: defaults,
            defaultsDomain: domain,
            timestamp: Date(timeIntervalSince1970: 1)
        )

        XCTAssertNil(backup, "no state file → nothing to back up")
        XCTAssertFalse(defaults.bool(forKey: "ouro.workbench.onboardingAutoPresented"), "prefs still cleared")
    }

    func testSecondResetInSameSecondDoesNotThrowAndOverwritesBackup() throws {
        let fm = FileManager.default
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let domain = "com.ourostack.workbench.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }

        let stateURL = dir.appendingPathComponent("workspace-state.json")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        // First reset: backup written.
        try Data("first".utf8).write(to: stateURL)
        let firstBackup = WorkbenchFactoryReset.wipeData(
            stateURL: stateURL, defaults: defaults, defaultsDomain: domain, timestamp: timestamp
        )
        XCTAssertNotNil(firstBackup)

        // Second reset, same second, fresh state file — must not throw on the
        // pre-existing backup; it gets overwritten with the newer state.
        try Data("second".utf8).write(to: stateURL)
        let secondBackup = WorkbenchFactoryReset.wipeData(
            stateURL: stateURL, defaults: defaults, defaultsDomain: domain, timestamp: timestamp
        )
        XCTAssertEqual(secondBackup, firstBackup)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(secondBackup)), "second")
    }
}
