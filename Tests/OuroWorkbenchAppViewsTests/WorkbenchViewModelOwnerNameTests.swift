#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

@MainActor
final class WorkbenchViewModelOwnerNameTests: XCTestCase {

    func testResolvedMachineOwnerUnderXCTestUsesShortUserWithoutFullNameLookup() {
        var fullNameCalled = false

        let owner = WorkbenchViewModel.resolvedMachineOwner(
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"],
            username: { "ari" },
            fullName: {
                fullNameCalled = true
                return "Ari Mendelow"
            },
            classLookup: { _ in nil }
        )

        XCTAssertEqual(owner?.id, "ari")
        XCTAssertEqual(owner?.name, "ari")
        XCTAssertFalse(fullNameCalled)
    }

    func testResolvedMachineOwnerCanUseLiveNameWhenExplicitlyEnabledUnderXCTest() {
        var fullNameCalled = false

        let owner = WorkbenchViewModel.resolvedMachineOwner(
            environment: [
                "XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration",
                "OURO_WORKBENCH_LIVE_OWNER_NAME": "1",
            ],
            username: { "ari" },
            fullName: {
                fullNameCalled = true
                return "Ari Mendelow"
            },
            classLookup: { _ in nil }
        )

        XCTAssertEqual(owner?.name, "Ari Mendelow")
        XCTAssertTrue(fullNameCalled)
    }

    func testResolvedMachineOwnerOutsideXCTestUsesFullNameLookup() {
        var fullNameCalled = false

        let owner = WorkbenchViewModel.resolvedMachineOwner(
            environment: [:],
            username: { "ari" },
            fullName: {
                fullNameCalled = true
                return "Ari Mendelow"
            },
            classLookup: { _ in nil }
        )

        XCTAssertEqual(owner?.id, "ari")
        XCTAssertEqual(owner?.name, "Ari Mendelow")
        XCTAssertTrue(fullNameCalled)
    }

    func testResolvedMachineOwnerDetectsBareXCTestClass() {
        var fullNameCalled = false

        let owner = WorkbenchViewModel.resolvedMachineOwner(
            environment: [:],
            username: { "ari" },
            fullName: {
                fullNameCalled = true
                return "Ari Mendelow"
            },
            classLookup: { name in name == "XCTestCase" ? NSObject.self : nil }
        )

        XCTAssertEqual(owner?.name, "ari")
        XCTAssertFalse(fullNameCalled)
    }

    func testResolvedMachineOwnerDetectsNamespacedXCTestClass() {
        var fullNameCalled = false

        let owner = WorkbenchViewModel.resolvedMachineOwner(
            environment: [:],
            username: { "ari" },
            fullName: {
                fullNameCalled = true
                return "Ari Mendelow"
            },
            classLookup: { name in name == "XCTest.XCTestCase" ? NSObject.self : nil }
        )

        XCTAssertEqual(owner?.name, "ari")
        XCTAssertFalse(fullNameCalled)
    }

    func testResolvedOwnerNameFallsBackWhenNoUserExists() {
        var fullNameCalled = false

        let name = WorkbenchViewModel.resolvedOwnerName(
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"],
            username: { "   " },
            fullName: {
                fullNameCalled = true
                return "Ari Mendelow"
            },
            classLookup: { _ in nil }
        )

        XCTAssertEqual(name, "the operator")
        XCTAssertFalse(fullNameCalled)
    }

    func testInitInjectsOwnerNameWithoutLiveLookup() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("owner-name-\(UUID().uuidString)", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState())

        let model = WorkbenchViewModel(
            paths: paths,
            ownerNameProvider: { "Dana" }
        )

        model.prepareBossCheckIn()

        let prompt = try XCTUnwrap(model.bossCheckInPrompt)
        XCTAssertTrue(
            prompt.contains("waiting on Dana"),
            "the injected owner should flow into the default boss check-in prompt"
        )
    }
}
#endif
