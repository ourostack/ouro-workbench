import CryptoKit
import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class HerdrIntegrationPackagingTests: XCTestCase {
    func testIntegrationAssetsPinTheReviewedRuntimeAndContainNoSecrets() throws {
        let root = repoRoot().appendingPathComponent("integrations/herdr", isDirectory: true)
        let manifestURL = root.appendingPathComponent("integration.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["id"] as? String, "ouro.herdr")
        let dependencies = try XCTUnwrap(object["dependencies"] as? [[String: Any]])
        XCTAssertTrue(dependencies.contains { $0["id"] as? String == "herdr" && $0["version"] as? String == "0.8.2" && $0["revision"] as? String == "9eb521456ac0d19d3ab3d9d7cea3cca10baa8a4c" })
        XCTAssertTrue(dependencies.contains { $0["id"] as? String == "herdr-mobile-relay" && $0["version"] as? String == "0.20.8" && $0["revision"] as? String == "fa64ecfb55db23a5b843d1deb78ef52f378b56be" })
        XCTAssertTrue(dependencies.contains { $0["id"] as? String == "github-copilot-cli" && $0["version"] as? String == "1.0.84-1" })

        let expected = Set(["README.md", "integration.json", "profiles.schema.json", "install.sh", "uninstall.sh"])
        let sums = try String(contentsOf: root.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(Set(sums.compactMap { $0.split(separator: " ").last.map(String.init) }), expected)
        for line in sums {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            XCTAssertEqual(fields.count, 2)
            let relativePath = String(fields[1])
            let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(String(fields[0]), digest, relativePath)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("github_pat_"))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("gho_"))
        }
    }

    func testAdaptersVerifyTheSignedBundleAndDelegateOnlyToTheHardenedHelper() throws {
        let root = repoRoot().appendingPathComponent("integrations/herdr", isDirectory: true)
        let install = try String(contentsOf: root.appendingPathComponent("install.sh"), encoding: .utf8)
        let uninstall = try String(contentsOf: root.appendingPathComponent("uninstall.sh"), encoding: .utf8)
        for script in [install, uninstall] {
            XCTAssertTrue(script.contains("codesign --verify --deep --strict"))
            XCTAssertTrue(script.contains("OuroWorkbenchRemote"))
            XCTAssertFalse(script.contains("eval "))
            XCTAssertFalse(script.contains("curl "))
            XCTAssertFalse(script.contains("git "))
            XCTAssertFalse(script.contains("GH_TOKEN"))
            XCTAssertFalse(script.contains("GITHUB_TOKEN"))
        }
        XCTAssertTrue(install.contains(" install "))
        XCTAssertTrue(uninstall.contains(" rollback "))
    }

    func testAppPackagingBuildsAndSealsAStandaloneRemoteArtifact() throws {
        let package = try source("scripts/package-app.sh")
        XCTAssertTrue(package.contains("--product \"$REMOTE_PRODUCT_NAME\""))
        XCTAssertTrue(package.contains("Contents/Resources"))
        XCTAssertTrue(package.contains("integrations/herdr"))
        XCTAssertTrue(package.contains(" package "))
        XCTAssertTrue(package.contains("--expected-helper-sha256"))

        let verifier = try source("scripts/verify-app-bundle.sh")
        XCTAssertTrue(verifier.contains("INTEGRATION_DIR"))
        XCTAssertTrue(verifier.contains("SHA256SUMS"))
        XCTAssertTrue(verifier.contains("RemoteArtifact") || verifier.contains("OuroWorkbenchRemote"))
        XCTAssertTrue(verifier.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(verifier.contains("plutil -convert json"))
        XCTAssertFalse(verifier.contains("plutil -lint \"$INTEGRATION_STATIC_DIR/integration.json\""))
    }

    func testMCPWiresOneReadOnlyNamespacedHealthToolWithoutProcessOwnership() throws {
        let source = try source("Sources/OuroWorkbenchMCP/OuroWorkbenchMCPMain.swift")
        XCTAssertTrue(source.contains("HerdrIntegrationHealth.toolName"))
        XCTAssertTrue(source.contains("HerdrIntegrationHealthReader.read"))
        let functionStart = try XCTUnwrap(source.range(of: "private func herdrIntegrationHealth() throws -> String"))
        let tail = source[functionStart.lowerBound...]
        let functionEnd = tail.range(of: "\n    private func")?.lowerBound ?? tail.endIndex
        let body = String(tail[..<functionEnd])
        XCTAssertFalse(body.contains("ProcessEntry"))
        XCTAssertFalse(body.contains("queue."))
        XCTAssertFalse(body.contains("requestAction"))
        XCTAssertTrue(body.contains("encodeJSON"))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
