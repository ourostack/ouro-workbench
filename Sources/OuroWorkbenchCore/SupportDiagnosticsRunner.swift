import Foundation

public struct SupportDiagnosticsResult: Equatable, Sendable {
    public var archiveURL: URL
    public var output: String

    public init(archiveURL: URL, output: String) {
        self.archiveURL = archiveURL
        self.output = output
    }
}

public enum SupportDiagnosticsRunnerError: Error, Equatable, LocalizedError, Sendable {
    case scriptMissing([String])
    case launchFailed(String)
    case failed(status: Int32, output: String)
    case archivePathMissing(String)
    case archiveMissing(String)

    public var errorDescription: String? {
        switch self {
        case let .scriptMissing(candidates):
            return "Support diagnostics helper is missing. Checked: \(candidates.joined(separator: ", "))"
        case let .launchFailed(message):
            return "Support diagnostics could not start: \(message)"
        case let .failed(status, output):
            return "Support diagnostics exited with status \(status): \(output)"
        case let .archivePathMissing(output):
            return "Support diagnostics did not report an archive path: \(output)"
        case let .archiveMissing(path):
            return "Support diagnostics reported a missing archive: \(path)"
        }
    }
}

public struct SupportDiagnosticsRunner: @unchecked Sendable {
    public let resourceDirectory: URL?
    public let currentDirectory: URL
    public let fileManager: FileManager

    private let scriptName = "collect-support-diagnostics.sh"

    public init(
        resourceDirectory: URL? = Bundle.main.resourceURL,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        fileManager: FileManager = .default
    ) {
        self.resourceDirectory = resourceDirectory
        self.currentDirectory = currentDirectory
        self.fileManager = fileManager
    }

    public var candidateScriptURLs: [URL] {
        var candidates: [URL] = []
        if let resourceDirectory {
            candidates.append(resourceDirectory.appendingPathComponent(scriptName))
        }
        candidates.append(currentDirectory.appendingPathComponent("scripts").appendingPathComponent(scriptName))
        candidates.append(currentDirectory.deletingLastPathComponent().appendingPathComponent("scripts").appendingPathComponent(scriptName))

        var seen = Set<String>()
        return candidates.filter { candidate in
            let path = candidate.standardizedFileURL.path
            guard !seen.contains(path) else {
                return false
            }
            seen.insert(path)
            return true
        }
    }

    public func scriptURL() -> URL? {
        candidateScriptURLs.first { candidate in
            fileManager.isExecutableFile(atPath: candidate.path)
        }
    }

    public func run() throws -> SupportDiagnosticsResult {
        guard let scriptURL = scriptURL() else {
            throw SupportDiagnosticsRunnerError.scriptMissing(candidateScriptURLs.map(\.path))
        }

        let process = Process()
        process.executableURL = scriptURL
        process.currentDirectoryURL = scriptURL.deletingLastPathComponent()
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw SupportDiagnosticsRunnerError.launchFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw SupportDiagnosticsRunnerError.failed(status: process.terminationStatus, output: output)
        }
        guard let archiveURL = Self.parseArchiveURL(from: output) else {
            throw SupportDiagnosticsRunnerError.archivePathMissing(output)
        }
        guard fileManager.fileExists(atPath: archiveURL.path) else {
            throw SupportDiagnosticsRunnerError.archiveMissing(archiveURL.path)
        }
        return SupportDiagnosticsResult(archiveURL: archiveURL, output: output)
    }

    public static func defaultOutputDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("OuroWorkbench", isDirectory: true)
            .appendingPathComponent("support-diagnostics", isDirectory: true)
    }

    public static func parseArchiveURL(from output: String) -> URL? {
        let prefix = "Wrote diagnostics: "
        for rawLine in output.split(whereSeparator: \.isNewline).reversed() {
            let line = String(rawLine)
            guard line.hasPrefix(prefix) else {
                continue
            }
            let path = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
