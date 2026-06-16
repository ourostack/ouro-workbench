import Foundation
import XCTest

func coverageBatch2TemporaryDirectory(named name: String = #function) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("ouro-coverage-batch-2", isDirectory: true)
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@discardableResult
func coverageBatch2InstallFakeOuro(
    in directory: URL,
    body: String = "exit 0\n"
) throws -> String {
    let bin = directory.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let ouro = bin.appendingPathComponent("ouro")
    try "#!/bin/sh\n\(body)".write(to: ouro, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ouro.path)
    let oldPath = getenv("PATH").map { String(cString: $0) } ?? ""
    setenv("PATH", "\(bin.path):\(oldPath)", 1)
    return oldPath
}

final class CoverageBatch2URLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (URLResponse, Data))?
    nonisolated(unsafe) static var error: Error?
    nonisolated(unsafe) static var shouldHang = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "coverage-batch-2.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if Self.shouldHang {
            return
        }
        if let error = Self.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        do {
            let (response, data) = try XCTUnwrap(Self.handler)(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        handler = nil
        error = nil
        shouldHang = false
    }
}

final class CoverageBatch2FileManager: FileManager, @unchecked Sendable {
    var executablePaths: Set<String> = []
    var existingPaths: Set<String> = []
    var moveError: Error?
    var removeError: Error?
    var removedPaths: [String] = []
    var movedPairs: [(String, String)] = []

    override func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }

    override func fileExists(atPath path: String) -> Bool {
        existingPaths.contains(path) || super.fileExists(atPath: path)
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if let moveError {
            throw moveError
        }
        movedPairs.append((srcURL.path, dstURL.path))
        try super.moveItem(at: srcURL, to: dstURL)
    }

    override func removeItem(at URL: URL) throws {
        removedPaths.append(URL.path)
        if let removeError {
            throw removeError
        }
        try? super.removeItem(at: URL)
    }
}

enum CoverageBatch2Error: Error, LocalizedError {
    case boom

    var errorDescription: String? { "boom" }
}
