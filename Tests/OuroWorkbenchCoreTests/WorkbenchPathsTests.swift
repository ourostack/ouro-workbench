import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchPathsTests: XCTestCase {
    func testDefaultPathsUsesApplicationSupportOuroWorkbenchRoot() {
        let paths = WorkbenchPaths.defaultPaths()

        XCTAssertEqual(paths.rootURL.lastPathComponent, "OuroWorkbench")
        XCTAssertTrue(paths.rootURL.path.contains("Application Support"))
        XCTAssertEqual(paths.stateURL.lastPathComponent, "workspace-state.json")
        XCTAssertEqual(paths.actionRequestsURL.lastPathComponent, "action-requests")
    }

    func testDefaultPathsFallsBackToHomeLibraryWhenApplicationSupportIsUnavailable() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let paths = WorkbenchPaths.defaultPaths(fileManager: NoApplicationSupportFileManager(homeURL: home))

        XCTAssertEqual(
            paths.rootURL.path,
            "/Users/example/Library/Application Support/OuroWorkbench"
        )
    }

    func testTranscriptURLNestsRunLogUnderEntryDirectory() {
        let root = URL(fileURLWithPath: "/Users/example/Library/Application Support/OuroWorkbench", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: root)
        let entryId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let runId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        XCTAssertEqual(
            paths.transcriptURL(entryId: entryId, runId: runId).path,
            root.appendingPathComponent("transcripts", isDirectory: true)
                .appendingPathComponent(entryId.uuidString, isDirectory: true)
                .appendingPathComponent("\(runId.uuidString).log").path
        )
    }

    private final class NoApplicationSupportFileManager: FileManager, @unchecked Sendable {
        private let fakeHomeURL: URL

        init(homeURL: URL) {
            fakeHomeURL = homeURL
            super.init()
        }

        override var homeDirectoryForCurrentUser: URL {
            fakeHomeURL
        }

        override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
            directory == .applicationSupportDirectory && domainMask == .userDomainMask ? [] : super.urls(for: directory, in: domainMask)
        }
    }
}
