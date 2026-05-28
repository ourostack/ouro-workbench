import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchWorkspaceConfigTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ouro-workbench-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testLoadDecodesAllFields() throws {
        let json = """
        {
            "group": "spoonjoy-v2",
            "rootPath": "~/Projects/spoonjoy-v2",
            "terminals": [
                {
                    "name": "dev server",
                    "command": "npm run dev",
                    "workingDirectory": ".",
                    "trust": "trusted",
                    "autoResume": true,
                    "notes": "vite + tailwind"
                },
                {
                    "name": "claude",
                    "command": "claude --resume"
                }
            ]
        }
        """
        try writeConfig(json)
        let loader = WorkbenchWorkspaceConfigLoader()
        let config = try loader.load(directoryPath: temporaryDirectory.path)

        XCTAssertEqual(config.group, "spoonjoy-v2")
        XCTAssertEqual(config.rootPath, "~/Projects/spoonjoy-v2")
        XCTAssertEqual(config.terminals.count, 2)
        XCTAssertEqual(config.terminals[0].name, "dev server")
        XCTAssertEqual(config.terminals[0].command, "npm run dev")
        XCTAssertEqual(config.terminals[0].trust, "trusted")
        XCTAssertEqual(config.terminals[0].autoResume, true)
        XCTAssertEqual(config.terminals[1].command, "claude --resume")
        XCTAssertNil(config.terminals[1].trust)
        XCTAssertNil(config.terminals[1].autoResume)
    }

    func testLoadFailsWhenFileMissing() throws {
        let loader = WorkbenchWorkspaceConfigLoader()
        do {
            _ = try loader.load(directoryPath: temporaryDirectory.path)
            XCTFail("Should have thrown configFileMissing")
        } catch WorkbenchWorkspaceConfigError.configFileMissing {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testLoadFailsOnMalformedJSON() throws {
        try writeConfig("{ this is not json")
        let loader = WorkbenchWorkspaceConfigLoader()
        do {
            _ = try loader.load(directoryPath: temporaryDirectory.path)
            XCTFail("Should have thrown malformedJSON")
        } catch WorkbenchWorkspaceConfigError.malformedJSON {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testLoadFailsWhenTerminalsEmpty() throws {
        try writeConfig(#"{"terminals": []}"#)
        let loader = WorkbenchWorkspaceConfigLoader()
        do {
            _ = try loader.load(directoryPath: temporaryDirectory.path)
            XCTFail("Should have thrown noTerminals")
        } catch WorkbenchWorkspaceConfigError.noTerminals {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testResolvedRootPathFallsBackToConfigDirectory() {
        let loader = WorkbenchWorkspaceConfigLoader()
        let config = WorkbenchWorkspaceConfig(terminals: [
            .init(name: "x", command: "true")
        ])
        let resolved = loader.resolvedRootPath(for: config, configDirectory: "/tmp/some/path")
        XCTAssertEqual(resolved, "/tmp/some/path")
    }

    func testResolvedRootPathExpandsTilde() {
        let loader = WorkbenchWorkspaceConfigLoader()
        let config = WorkbenchWorkspaceConfig(
            rootPath: "~/Projects/foo",
            terminals: [.init(name: "x", command: "true")]
        )
        let resolved = loader.resolvedRootPath(for: config, configDirectory: "/tmp")
        XCTAssertFalse(resolved.contains("~"))
        XCTAssertTrue(resolved.hasSuffix("Projects/foo"))
    }

    func testResolvedWorkingDirectoryHandlesDotAndRelativePaths() {
        let loader = WorkbenchWorkspaceConfigLoader()
        let root = "/tmp/work"

        XCTAssertEqual(
            loader.resolvedWorkingDirectory(
                for: .init(name: "x", command: "true", workingDirectory: nil),
                rootPath: root
            ),
            root
        )
        XCTAssertEqual(
            loader.resolvedWorkingDirectory(
                for: .init(name: "x", command: "true", workingDirectory: "."),
                rootPath: root
            ),
            root
        )
        XCTAssertEqual(
            loader.resolvedWorkingDirectory(
                for: .init(name: "x", command: "true", workingDirectory: "frontend"),
                rootPath: root
            ),
            "/tmp/work/frontend"
        )
        XCTAssertEqual(
            loader.resolvedWorkingDirectory(
                for: .init(name: "x", command: "true", workingDirectory: "/abs/path"),
                rootPath: root
            ),
            "/abs/path"
        )
    }

    func testResolvedGroupNameFallsBackToRootBasename() {
        let loader = WorkbenchWorkspaceConfigLoader()
        let config = WorkbenchWorkspaceConfig(terminals: [
            .init(name: "x", command: "true")
        ])
        XCTAssertEqual(
            loader.resolvedGroupName(for: config, rootPath: "/tmp/work/spoonjoy-v2"),
            "spoonjoy-v2"
        )
    }

    func testResolvedGroupNameUsesConfiguredValue() {
        let loader = WorkbenchWorkspaceConfigLoader()
        let config = WorkbenchWorkspaceConfig(group: "custom", terminals: [
            .init(name: "x", command: "true")
        ])
        XCTAssertEqual(
            loader.resolvedGroupName(for: config, rootPath: "/tmp/work/something-else"),
            "custom"
        )
    }

    private func writeConfig(_ contents: String) throws {
        let url = temporaryDirectory.appendingPathComponent(WorkbenchWorkspaceConfigLoader.configFileName)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
