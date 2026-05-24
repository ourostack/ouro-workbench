import Foundation

public enum ExecutableHealthStatus: String, Codable, Equatable, Sendable {
    case available
    case missing
    case notExecutable
}

public struct ExecutableHealth: Codable, Equatable, Sendable {
    public var executable: String
    public var resolvedPath: String?
    public var status: ExecutableHealthStatus
    public var detail: String

    public init(
        executable: String,
        resolvedPath: String? = nil,
        status: ExecutableHealthStatus,
        detail: String
    ) {
        self.executable = executable
        self.resolvedPath = resolvedPath
        self.status = status
        self.detail = detail
    }
}

public struct ExecutableHealthChecker {
    public var environment: TerminalEnvironment
    public var fileManager: FileManager

    public init(
        environment: TerminalEnvironment = TerminalEnvironment(),
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.fileManager = fileManager
    }

    public func health(for executable: String) -> ExecutableHealth {
        let trimmed = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ExecutableHealth(
                executable: executable,
                status: .missing,
                detail: "No executable configured."
            )
        }

        if trimmed.contains("/") {
            return healthAtPath(trimmed, executable: executable)
        }

        for directory in pathDirectories() {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(trimmed)
                .path
            if fileManager.fileExists(atPath: candidate) {
                return healthAtPath(candidate, executable: executable)
            }
        }

        return ExecutableHealth(
            executable: executable,
            status: .missing,
            detail: "\(trimmed) was not found on PATH."
        )
    }

    private func healthAtPath(_ path: String, executable: String) -> ExecutableHealth {
        guard fileManager.fileExists(atPath: path) else {
            return ExecutableHealth(
                executable: executable,
                resolvedPath: path,
                status: .missing,
                detail: "\(path) does not exist."
            )
        }
        guard fileManager.isExecutableFile(atPath: path) else {
            return ExecutableHealth(
                executable: executable,
                resolvedPath: path,
                status: .notExecutable,
                detail: "\(path) is not executable."
            )
        }
        return ExecutableHealth(
            executable: executable,
            resolvedPath: path,
            status: .available,
            detail: "Found \(path)."
        )
    }

    private func pathDirectories() -> [String] {
        let path = TerminalEnvironment.resolvedPath(from: environment.values)
        return path.split(separator: ":").map(String.init)
    }
}
