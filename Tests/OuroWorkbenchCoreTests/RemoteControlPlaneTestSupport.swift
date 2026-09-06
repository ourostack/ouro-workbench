import Foundation
import XCTest
@testable import OuroWorkbenchCore

func remoteTemporaryDirectory(_ name: String = #function) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ouro-remote-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    return root
}

func remoteRegistryObject(profileCount: Int = 2) -> [String: Any] {
    let profiles: [[String: Any]] = [
        [
            "id": "personal",
            "githubLogin": "arimendelow",
            "displayLabel": "Personal",
            "displayColor": "#6F42C1",
            "copilotHome": "/tmp/ouro/copilot/personal",
            "ghConfigDir": "/tmp/ouro/gh/personal",
            "gitConfigGlobal": "/tmp/ouro/git/personal/config",
            "allowedGitHubOwners": ["arimendelow", "ourostack"],
            "commitName": "Ari Mendel",
            "commitEmail": "ari@example.test",
            "copilotExecutable": "/fixtures/bin/copilot",
            "ghExecutable": "/fixtures/bin/gh",
            "gitExecutable": "/fixtures/bin/git",
            "herdrExecutable": "/fixtures/bin/herdr",
            "zshExecutable": "/bin/zsh",
            "deskRoot": "/tmp/desk",
            "workerID": "desk:worker",
            "continuationCap": 100,
            "remote": true,
            "autonomy": true
        ],
        [
            "id": "emu",
            "githubLogin": "arimendelow_microsoft",
            "displayLabel": "Managed",
            "displayColor": "#0969DA",
            "copilotHome": "/tmp/ouro/copilot/emu",
            "ghConfigDir": "/tmp/ouro/gh/emu",
            "gitConfigGlobal": "/tmp/ouro/git/emu/config",
            "allowedGitHubOwners": ["managed-org"],
            "commitName": "Ari Managed",
            "commitEmail": "ari@managed.example.test",
            "copilotExecutable": "/fixtures/bin/copilot",
            "ghExecutable": "/fixtures/bin/gh",
            "gitExecutable": "/fixtures/bin/git",
            "herdrExecutable": "/fixtures/bin/herdr",
            "zshExecutable": "/bin/zsh",
            "deskRoot": "/tmp/managed-desk",
            "workerID": "desk:worker",
            "continuationCap": 100,
            "remote": true,
            "autonomy": true
        ]
    ]
    return ["schemaVersion": 1, "profiles": Array(profiles.prefix(profileCount))]
}

func remoteJSONData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

func remoteRegistry(profileCount: Int = 2) throws -> RemoteProfileRegistry {
    try RemoteProfileRegistry.decode(
        try remoteJSONData(remoteRegistryObject(profileCount: profileCount)),
        executableExists: { _ in true }
    )
}

func assertRemoteErrorContains(
    _ text: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () throws -> Void
) {
    XCTAssertThrowsError(try operation(), file: file, line: line) { error in
        XCTAssertTrue(error.localizedDescription.contains(text), "\(error)", file: file, line: line)
    }
}

final class RemoteCallRecorder {
    var calls: [RemoteProcessRequest] = []
    var responses: [RemoteProcessResult]
    var thrownError: Error?

    init(responses: [RemoteProcessResult] = []) {
        self.responses = responses
    }

    func run(_ request: RemoteProcessRequest) throws -> RemoteProcessResult {
        calls.append(request)
        if let thrownError {
            throw thrownError
        }
        return responses.isEmpty ? RemoteProcessResult(exitCode: 0) : responses.removeFirst()
    }
}

enum RemoteFixtureError: Error {
    case expected
}

func remoteProcessIdentity(
    pid: Int32 = 200,
    startIdentity: String = "birth-200",
    executable: String = "/fixtures/bin/copilot",
    generation: String = "g1"
) -> RemoteProcessIdentity {
    RemoteProcessIdentity(
        pid: pid,
        startIdentity: startIdentity,
        executable: executable,
        generation: generation
    )
}
