import Darwin
import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class RemoteLastKnownGoodTests: XCTestCase {
    func testCapturePublishesOneImmutableDigestBoundGeneration() throws {
        let fixture = try LastKnownGoodFixture()
        defer { fixture.remove() }
        XCTAssertEqual(mkfifo(fixture.sourceSessionURL.appendingPathComponent("herdr.sock").path, 0o600), 0)
        XCTAssertEqual(mkfifo(fixture.sourceSessionURL.appendingPathComponent("herdr-client.sock").path, 0o600), 0)
        let store = RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { "capture-a" })

        let manifest = try store.capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)

        XCTAssertEqual(manifest.captureID, "capture-a")
        XCTAssertEqual(manifest.sourceGeneration, fixture.generation)
        XCTAssertEqual(manifest.generationManifest.sourceSession, fixture.generation)
        XCTAssertEqual(manifest.generationManifest.expectedPanes, fixture.expectedPanes)
        XCTAssertFalse(manifest.generationManifest.acknowledgedEmpty)
        XCTAssertEqual(try String(contentsOf: fixture.currentURL, encoding: .utf8), "capture-a\n")
        XCTAssertEqual(try JSONDecoder().decode(RemoteLastKnownGoodManifest.self, from: Data(contentsOf: fixture.captureManifestURL("capture-a"))), manifest)
        XCTAssertEqual(try Data(contentsOf: fixture.capturedSessionURL("capture-a").appendingPathComponent("session.json")), fixture.sessionBytes)
        XCTAssertEqual(try permissions(at: fixture.captureRootURL("capture-a")), 0o700)
        XCTAssertEqual(try permissions(at: fixture.captureManifestURL("capture-a")), 0o600)
        XCTAssertEqual(try permissions(at: fixture.capturedSessionURL("capture-a")), 0o700)
        XCTAssertEqual(try permissions(at: fixture.capturedSessionURL("capture-a").appendingPathComponent("session.json")), 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.capturedSessionURL("capture-a").appendingPathComponent("herdr.sock").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.capturedSessionURL("capture-a").appendingPathComponent("herdr-client.sock").path))
        XCTAssertNotEqual(try inode(at: fixture.sourceSessionURL.appendingPathComponent("session.json")), try inode(at: fixture.capturedSessionURL("capture-a").appendingPathComponent("session.json")))
        XCTAssertEqual(try store.loadCurrent().manifest, manifest)
        XCTAssertEqual(try store.loadCurrent().snapshotURL, fixture.capturedSessionURL("capture-a"))

        assertRemoteErrorContains("already exists") {
            _ = try store.capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)
        }
        XCTAssertEqual(try String(contentsOf: fixture.currentURL, encoding: .utf8), "capture-a\n")
    }

    func testCaptureRequiresAnExactGenerationAcknowledgementForAnEmptyFleet() throws {
        let fixture = try LastKnownGoodFixture()
        defer { fixture.remove() }
        let empty = RemoteHerdrInventory(version: "0.8.2", panes: [])

        assertRemoteErrorContains("explicit empty-fleet acknowledgement") {
            _ = try RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { "empty-a" }).capture(sourceGeneration: fixture.generation, inventory: empty)
        }
        assertRemoteErrorContains("does not match the active generation") {
            _ = try RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { "empty-b" }).capture(sourceGeneration: fixture.generation, inventory: empty, acknowledgedEmptyGeneration: "ouro-stale")
        }
        assertRemoteErrorContains("only valid for an empty fleet") {
            _ = try RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { "empty-c" }).capture(sourceGeneration: fixture.generation, inventory: fixture.inventory, acknowledgedEmptyGeneration: fixture.generation)
        }

        let manifest = try RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { "empty-good" }).capture(sourceGeneration: fixture.generation, inventory: empty, acknowledgedEmptyGeneration: fixture.generation)
        XCTAssertTrue(manifest.generationManifest.acknowledgedEmpty)
        XCTAssertTrue(manifest.generationManifest.expectedPanes.isEmpty)
        XCTAssertEqual(manifest.sourceGeneration, fixture.generation)
    }

    func testCaptureRejectsInventoryThatIsNotExactHealthyGenerationEvidence() throws {
        let fixture = try LastKnownGoodFixture()
        defer { fixture.remove() }
        let store = RemoteLastKnownGoodStore(rootURL: fixture.root)
        let base = fixture.inventory.panes[0]
        var cases: [(RemoteHerdrInventory, String)] = []
        cases.append((RemoteHerdrInventory(version: "0.9.0", panes: fixture.inventory.panes), "Herdr version"))
        var wrongGeneration = base
        wrongGeneration.generation = "ouro-other"
        cases.append((RemoteHerdrInventory(version: "0.8.2", panes: [wrongGeneration]), "generation"))
        var missingNative = base
        missingNative.nativeSessionID = nil
        cases.append((RemoteHerdrInventory(version: "0.8.2", panes: [missingNative]), "complete healthy"))
        var missingProfile = base
        missingProfile.profileID = nil
        cases.append((RemoteHerdrInventory(version: "0.8.2", panes: [missingProfile]), "complete healthy"))
        var missingLogin = base
        missingLogin.githubLogin = nil
        cases.append((RemoteHerdrInventory(version: "0.8.2", panes: [missingLogin]), "complete healthy"))
        var noChild = base
        noChild.childPresent = false
        cases.append((RemoteHerdrInventory(version: "0.8.2", panes: [noChild]), "complete healthy"))
        var noHook = base
        noHook.hookObserved = false
        cases.append((RemoteHerdrInventory(version: "0.8.2", panes: [noHook]), "complete healthy"))
        var noWrapper = base
        noWrapper.wrapperReady = false
        cases.append((RemoteHerdrInventory(version: "0.8.2", panes: [noWrapper]), "complete healthy"))
        var noProcess = base
        noProcess.foregroundProcess = nil
        cases.append((RemoteHerdrInventory(version: "0.8.2", panes: [noProcess]), "complete healthy"))
        var wrongProcessGeneration = base
        wrongProcessGeneration.foregroundProcess?.generation = "ouro-other"
        cases.append((RemoteHerdrInventory(version: "0.8.2", panes: [wrongProcessGeneration]), "complete healthy"))
        var invalidUUID = base
        invalidUUID.nativeSessionID = "not-a-uuid"
        cases.append((RemoteHerdrInventory(version: "0.8.2", panes: [invalidUUID]), "UUID"))
        var unsafePane = base
        unsafePane.paneID = "bad\n"
        cases.append((RemoteHerdrInventory(version: "0.8.2", panes: [unsafePane]), "identity"))
        var duplicatePane = fixture.inventory.panes[1]
        duplicatePane.paneID = base.paneID
        cases.append((RemoteHerdrInventory(version: "0.8.2", panes: [base, duplicatePane]), "duplicate"))
        var duplicateNative = fixture.inventory.panes[1]
        duplicateNative.nativeSessionID = base.nativeSessionID
        cases.append((RemoteHerdrInventory(version: "0.8.2", panes: [base, duplicateNative]), "duplicate"))

        for (inventory, error) in cases {
            assertRemoteErrorContains(error) {
                _ = try store.capture(sourceGeneration: fixture.generation, inventory: inventory)
            }
        }
        assertRemoteErrorContains("generation name") {
            _ = try store.capture(sourceGeneration: "../unsafe", inventory: fixture.inventory)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.currentURL.path))
    }

    func testCaptureRejectsUnsafeOrIncompleteSnapshotTreesBeforePublication() throws {
        for mutation in ["missing-session", "root-mode", "file-mode", "symlink", "hardlink", "special"] {
            let fixture = try LastKnownGoodFixture(name: mutation)
            defer { fixture.remove() }
            switch mutation {
            case "missing-session": try FileManager.default.removeItem(at: fixture.sourceSessionURL.appendingPathComponent("session.json"))
            case "root-mode": try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.sourceSessionURL.path)
            case "file-mode": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.sourceSessionURL.appendingPathComponent("session.json").path)
            case "symlink": try FileManager.default.createSymbolicLink(at: fixture.sourceSessionURL.appendingPathComponent("linked"), withDestinationURL: fixture.sourceSessionURL.appendingPathComponent("session.json"))
            case "hardlink": try FileManager.default.linkItem(at: fixture.sourceSessionURL.appendingPathComponent("session.json"), to: fixture.sourceSessionURL.appendingPathComponent("hard"))
            case "special": XCTAssertEqual(mkfifo(fixture.sourceSessionURL.appendingPathComponent("unexpected.fifo").path, 0o600), 0)
            default: XCTFail("unknown fixture")
            }

            assertRemoteErrorContains("snapshot") {
                _ = try RemoteLastKnownGoodStore(rootURL: fixture.root).capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.currentURL.path))
        }
    }

    func testCaptureKeepsThePriorSelectionAcrossEveryPrePublicationInterruption() throws {
        for interruptedAt in RemoteLastKnownGoodCheckpoint.allCases {
            let fixture = try LastKnownGoodFixture(name: interruptedAt.rawValue)
            defer { fixture.remove() }
            let oldStore = RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { "old" })
            _ = try oldStore.capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)
            let store = RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { "new" })

            assertRemoteErrorContains("interrupted") {
                _ = try store.capture(sourceGeneration: fixture.generation, inventory: fixture.inventory) { point in
                    if point == interruptedAt { throw RemoteFixtureError.expected }
                }
            }

            XCTAssertEqual(try String(contentsOf: fixture.currentURL, encoding: .utf8), "old\n")
            XCTAssertEqual(try store.loadCurrent().manifest.captureID, "old")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.generationsURL.appendingPathComponent(".new.stage").path))
            if interruptedAt == .generationPromoted {
                XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.captureRootURL("new").path))
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.captureRootURL("new").path))
            }
        }
    }

    func testCaptureTranslatesExclusiveLockAndAtomicPublicationFailures() throws {
        do {
            let fixture = try LastKnownGoodFixture(name: "lock")
            defer { fixture.remove() }
            try FileManager.default.createDirectory(at: fixture.generationsURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.lastKnownGoodURL.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.generationsURL.path)
            let lock = try RemoteAdvisoryLock.acquire(url: fixture.lastKnownGoodURL.appendingPathComponent("capture.lock"))
            defer { lock.release() }

            assertRemoteErrorContains("already running or unavailable") {
                _ = try RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { "locked" }).capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)
            }
        }

        do {
            let fixture = try LastKnownGoodFixture(name: "manifest-write")
            defer { fixture.remove() }
            let captureID = "manifest-write"
            let manifestURL = fixture.generationsURL.appendingPathComponent(".\(captureID).stage/manifest.json", isDirectory: true)

            assertRemoteErrorContains("manifest could not be written") {
                _ = try RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { captureID }).capture(sourceGeneration: fixture.generation, inventory: fixture.inventory) { point in
                    if point == .snapshotCopied {
                        try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    }
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.currentURL.path))
        }

        do {
            let fixture = try LastKnownGoodFixture(name: "generation-promotion")
            defer { fixture.remove() }
            let captureID = "promotion-failure"

            assertRemoteErrorContains("generation could not be promoted") {
                _ = try RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { captureID }).capture(sourceGeneration: fixture.generation, inventory: fixture.inventory) { point in
                    if point == .manifestWritten {
                        try FileManager.default.createDirectory(at: fixture.captureRootURL(captureID), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    }
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.currentURL.path))
        }

        do {
            let fixture = try LastKnownGoodFixture(name: "selection-publication")
            defer { fixture.remove() }
            let captureID = "publication-failure"

            assertRemoteErrorContains("selection could not be published") {
                _ = try RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { captureID }).capture(sourceGeneration: fixture.generation, inventory: fixture.inventory) { point in
                    if point == .generationPromoted {
                        try FileManager.default.createDirectory(at: fixture.currentURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    }
                }
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.captureRootURL(captureID).path))
        }
    }

    func testCaptureTranslatesStorageCreationLookupAndHardeningFailures() throws {
        do {
            let fixture = try LastKnownGoodFixture(name: "creation-acl")
            defer { fixture.remove() }
            try addDenyACL("add_subdirectory", to: fixture.root)
            defer { try? removeACL(from: fixture.root) }

            assertRemoteErrorContains("could not be created") {
                _ = try RemoteLastKnownGoodStore(rootURL: fixture.root).capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)
            }
        }

        do {
            let fixture = try LastKnownGoodFixture(name: "lookup-acl")
            defer { fixture.remove() }
            _ = try RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { "first" }).capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)
            try addDenyACL("search", to: fixture.generationsURL)
            defer { try? removeACL(from: fixture.generationsURL) }

            assertRemoteErrorContains("generation is unavailable") {
                _ = try RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { "second" }).capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)
            }
        }

        do {
            let fixture = try LastKnownGoodFixture(name: "immutable-directory")
            defer { fixture.remove() }
            try FileManager.default.createDirectory(at: fixture.lastKnownGoodURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            XCTAssertEqual(chflags(fixture.lastKnownGoodURL.path, UInt32(UF_IMMUTABLE)), 0)
            defer { _ = chflags(fixture.lastKnownGoodURL.path, 0) }

            assertRemoteErrorContains("permissions could not be secured") {
                _ = try RemoteLastKnownGoodStore(rootURL: fixture.root).capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)
            }
        }
    }

    func testCaptureTranslatesSourceEnumerationEntryAndCopyFailures() throws {
        do {
            let fixture = try LastKnownGoodFixture(name: "source-list-acl")
            defer { fixture.remove() }
            try addDenyACL("list", to: fixture.sourceSessionURL)
            defer { try? removeACL(from: fixture.sourceSessionURL) }

            assertRemoteErrorContains("source snapshot is unreadable") {
                _ = try RemoteLastKnownGoodStore(rootURL: fixture.root).capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)
            }
        }

        do {
            let fixture = try LastKnownGoodFixture(name: "source-entry-acl")
            defer { fixture.remove() }
            let entry = fixture.sourceSessionURL.appendingPathComponent("state/pane.json")
            try addDenyACL("readattr", to: entry)
            defer { try? removeACL(from: entry) }

            assertRemoteErrorContains("source snapshot entry is unreadable") {
                _ = try RemoteLastKnownGoodStore(rootURL: fixture.root).capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)
            }
        }

        do {
            let fixture = try LastKnownGoodFixture(name: "source-directory-mode")
            defer { fixture.remove() }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.sourceSessionURL.appendingPathComponent("state").path)

            assertRemoteErrorContains("source snapshot directory permissions are unsafe") {
                _ = try RemoteLastKnownGoodStore(rootURL: fixture.root).capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)
            }
        }

        do {
            let fixture = try LastKnownGoodFixture(name: "source-read-acl")
            defer { fixture.remove() }
            let entry = fixture.sourceSessionURL.appendingPathComponent("state/pane.json")
            try addDenyACL("read", to: entry)
            defer { try? removeACL(from: entry) }

            assertRemoteErrorContains("source snapshot entry could not be copied") {
                _ = try RemoteLastKnownGoodStore(rootURL: fixture.root).capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)
            }
        }
    }

    func testLoadAndVerificationTranslateInterruptionsAndSnapshotFilesystemFailures() throws {
        do {
            let fixture = try LastKnownGoodFixture(name: "pointer-interruption")
            defer { fixture.remove() }
            let store = RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { "capture" })
            _ = try store.capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)

            assertRemoteErrorContains("selection read was interrupted") {
                _ = try store.loadCurrent(afterPointerRead: { throw RemoteFixtureError.expected })
            }
        }

        do {
            let fixture = try LastKnownGoodFixture(name: "snapshot-list-acl")
            defer { fixture.remove() }
            let store = RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { "capture" })
            _ = try store.capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)
            let selected = try store.loadCurrent()
            try addDenyACL("list", to: selected.snapshotURL)
            defer { try? removeACL(from: selected.snapshotURL) }

            assertRemoteErrorContains("snapshot is unreadable") { try selected.verifyCopiedSnapshot(at: selected.snapshotURL) }
        }

        do {
            let fixture = try LastKnownGoodFixture(name: "snapshot-entry-acl")
            defer { fixture.remove() }
            let store = RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { "capture" })
            _ = try store.capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)
            let selected = try store.loadCurrent()
            let entry = selected.snapshotURL.appendingPathComponent("state/pane.json")
            try addDenyACL("readattr", to: entry)
            defer { try? removeACL(from: entry) }

            assertRemoteErrorContains("snapshot entry is unreadable") { try selected.verifyCopiedSnapshot(at: selected.snapshotURL) }
        }

        do {
            let fixture = try LastKnownGoodFixture(name: "snapshot-directory-mode")
            defer { fixture.remove() }
            let store = RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { "capture" })
            _ = try store.capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)
            let selected = try store.loadCurrent()
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: selected.snapshotURL.appendingPathComponent("state").path)

            assertRemoteErrorContains("snapshot directory permissions are unsafe") { try selected.verifyCopiedSnapshot(at: selected.snapshotURL) }
        }

        do {
            let fixture = try LastKnownGoodFixture(name: "snapshot-read-acl")
            defer { fixture.remove() }
            let store = RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { "capture" })
            _ = try store.capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)
            let selected = try store.loadCurrent()
            let entry = selected.snapshotURL.appendingPathComponent("state/pane.json")
            try addDenyACL("read", to: entry)
            defer { try? removeACL(from: entry) }

            assertRemoteErrorContains("unreadable or exceeds") { try selected.verifyCopiedSnapshot(at: selected.snapshotURL) }
        }

        do {
            let fixture = try LastKnownGoodFixture(name: "snapshot-special")
            defer { fixture.remove() }
            let store = RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { "capture" })
            _ = try store.capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)
            let selected = try store.loadCurrent()
            XCTAssertEqual(mkfifo(selected.snapshotURL.appendingPathComponent("unexpected.fifo").path, 0o600), 0)

            assertRemoteErrorContains("special entry") { try selected.verifyCopiedSnapshot(at: selected.snapshotURL) }
        }
    }

    func testLoadCurrentReadsOneSelectionEvenWhenThePointerChangesAfterRead() throws {
        let fixture = try LastKnownGoodFixture()
        defer { fixture.remove() }
        _ = try RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { "capture-a" }).capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)
        fixture.sessionBytes = Data("second-generation".utf8)
        try fixture.sessionBytes.write(to: fixture.sourceSessionURL.appendingPathComponent("session.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.sourceSessionURL.appendingPathComponent("session.json").path)
        _ = try RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { "capture-b" }).capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)
        try Data("capture-a\n".utf8).write(to: fixture.currentURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.currentURL.path)
        let store = RemoteLastKnownGoodStore(rootURL: fixture.root)

        let selected = try store.loadCurrent(afterPointerRead: {
            try Data("capture-b\n".utf8).write(to: fixture.currentURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.currentURL.path)
        })

        XCTAssertEqual(selected.manifest.captureID, "capture-a")
        XCTAssertEqual(try Data(contentsOf: selected.snapshotURL.appendingPathComponent("session.json")), Data("lkg-session".utf8))
        XCTAssertEqual(try String(contentsOf: fixture.currentURL, encoding: .utf8), "capture-b\n")
    }

    func testLoadAndVerificationRejectCorruptSelectionAndSnapshotTampering() throws {
        let fixture = try LastKnownGoodFixture()
        defer { fixture.remove() }
        let store = RemoteLastKnownGoodStore(rootURL: fixture.root, makeCaptureID: { "capture-a" })
        _ = try store.capture(sourceGeneration: fixture.generation, inventory: fixture.inventory)
        let validPointer = try Data(contentsOf: fixture.currentURL)
        let validManifest = try Data(contentsOf: fixture.captureManifestURL("capture-a"))

        for pointer in ["", "../escape", "missing", String(repeating: "x", count: 129)] {
            try Data("\(pointer)\n".utf8).write(to: fixture.currentURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.currentURL.path)
            assertRemoteErrorContains("selection") { _ = try store.loadCurrent() }
        }
        try validPointer.write(to: fixture.currentURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.currentURL.path)

        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["unknown"] = true },
            { $0["schemaVersion"] = 2 },
            { $0["captureID"] = "capture-b" },
            { $0["sourceGeneration"] = "ouro-other" },
            { $0["snapshotSHA256"] = "bad" },
            { $0["generationManifest"] = [] }
        ]
        for mutate in mutations {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: validManifest) as? [String: Any])
            mutate(&object)
            try remoteJSONData(object).write(to: fixture.captureManifestURL("capture-a"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.captureManifestURL("capture-a").path)
            assertRemoteErrorContains("manifest") { _ = try store.loadCurrent() }
        }
        try validManifest.write(to: fixture.captureManifestURL("capture-a"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.captureManifestURL("capture-a").path)

        try Data("tampered".utf8).write(to: fixture.capturedSessionURL("capture-a").appendingPathComponent("session.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.capturedSessionURL("capture-a").appendingPathComponent("session.json").path)
        let selected = try store.loadCurrent()
        assertRemoteErrorContains("digest") { try selected.verifyCopiedSnapshot(at: selected.snapshotURL) }
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func inode(at url: URL) throws -> UInt64 {
        var value = stat()
        XCTAssertEqual(lstat(url.path, &value), 0)
        return UInt64(value.st_ino)
    }

    private func addDenyACL(_ permission: String, to url: URL) throws {
        try runChmod(["+a", "everyone deny \(permission)", url.path])
    }

    private func removeACL(from url: URL) throws {
        try runChmod(["-N", url.path])
    }

    private func runChmod(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

private final class LastKnownGoodFixture {
    let root: URL
    let generation = "ouro-live"
    var sessionBytes = Data("lkg-session".utf8)

    init(name: String = #function) throws {
        root = try remoteTemporaryDirectory("lkg-\(name)")
        try FileManager.default.createDirectory(at: sourceSessionURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("sessions").path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sourceSessionURL.path)
        try sessionBytes.write(to: sourceSessionURL.appendingPathComponent("session.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceSessionURL.appendingPathComponent("session.json").path)
        let nested = sourceSessionURL.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("pane-state".utf8).write(to: nested.appendingPathComponent("pane.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nested.appendingPathComponent("pane.json").path)
    }

    var expectedPanes: [RemoteExpectedPane] {
        inventory.panes.map {
            RemoteExpectedPane(workspaceID: $0.workspaceID, paneID: $0.paneID, nativeSessionID: $0.nativeSessionID!, profileID: $0.profileID!, githubLogin: $0.githubLogin!)
        }
    }

    var inventory: RemoteHerdrInventory {
        RemoteHerdrInventory(version: "0.8.2", panes: [
            pane(workspace: "desk", pane: "desk:p1", uuid: "8d5177d6-b6d1-4b5f-a546-564ed0ef8748", profile: "personal", login: "arimendelow", pid: 101),
            pane(workspace: "desk", pane: "desk:p2", uuid: "29633c1f-f185-41a7-b628-8f7e54d74422", profile: "emu", login: "arimendelow_microsoft", pid: 102)
        ])
    }

    var sourceSessionURL: URL { root.appendingPathComponent("sessions/\(generation)", isDirectory: true) }
    var lastKnownGoodURL: URL { root.appendingPathComponent("last-known-good", isDirectory: true) }
    var generationsURL: URL { lastKnownGoodURL.appendingPathComponent("generations", isDirectory: true) }
    var currentURL: URL { lastKnownGoodURL.appendingPathComponent("current") }
    func captureRootURL(_ id: String) -> URL { generationsURL.appendingPathComponent(id, isDirectory: true) }
    func captureManifestURL(_ id: String) -> URL { captureRootURL(id).appendingPathComponent("manifest.json") }
    func capturedSessionURL(_ id: String) -> URL { captureRootURL(id).appendingPathComponent("session", isDirectory: true) }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func pane(workspace: String, pane: String, uuid: String, profile: String, login: String, pid: Int32) -> RemotePaneInventory {
        RemotePaneInventory(
            workspaceID: workspace,
            paneID: pane,
            nativeSessionID: uuid,
            profileID: profile,
            githubLogin: login,
            generation: generation,
            childPresent: true,
            hookObserved: true,
            wrapperReady: true,
            foregroundProcess: remoteProcessIdentity(pid: pid, startIdentity: "birth-\(pid)", generation: generation)
        )
    }
}
