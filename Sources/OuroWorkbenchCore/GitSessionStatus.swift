import Foundation

/// Git status for a single terminal session's working directory: which branch
/// it's on, whether the tree is dirty, and how far ahead/behind its upstream.
/// For an agent workbench whose terminals usually live in worktrees/branches,
/// this is the "where am I" glance the operator (and the boss) want per session.
public struct GitSessionStatus: Equatable, Sendable, Codable {
    /// False when the working directory isn't a git repo (or git/dir is missing).
    public var isRepo: Bool
    /// Branch name, or nil when detached / unknown.
    public var branch: String?
    public var detached: Bool
    /// Any tracked modification, staged change, unmerged path, or untracked file.
    public var dirty: Bool
    /// Commits ahead / behind the upstream (0 when no upstream is configured).
    public var ahead: Int
    public var behind: Int

    public init(
        isRepo: Bool,
        branch: String? = nil,
        detached: Bool = false,
        dirty: Bool = false,
        ahead: Int = 0,
        behind: Int = 0
    ) {
        self.isRepo = isRepo
        self.branch = branch
        self.detached = detached
        self.dirty = dirty
        self.ahead = ahead
        self.behind = behind
    }

    /// Sentinel for "this directory is not a git repository".
    public static let notARepo = GitSessionStatus(isRepo: false)

    /// A compact human label, e.g. `main`, `(detached)`, or nil when not a repo.
    public var branchLabel: String? {
        guard isRepo else { return nil }
        if detached { return "(detached)" }
        return branch ?? "(unknown)"
    }

    /// A compact ahead/behind suffix like `↑2↓1`, or nil when in sync / no upstream.
    public var aheadBehindLabel: String? {
        guard ahead > 0 || behind > 0 else { return nil }
        var parts: [String] = []
        if ahead > 0 { parts.append("↑\(ahead)") }
        if behind > 0 { parts.append("↓\(behind)") }
        return parts.joined()
    }

    /// Parse `git status --porcelain=v2 --branch` output into a status value.
    /// The v2 format is stable and machine-oriented:
    ///   `# branch.head <name>` (or `(detached)`), `# branch.ab +A -B`,
    ///   and `1`/`2`/`u`/`?` lines for staged/unstaged/unmerged/untracked entries.
    public static func parse(porcelainV2 output: String) -> GitSessionStatus {
        var branch: String?
        var detached = false
        var dirty = false
        var ahead = 0
        var behind = 0

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("# branch.head ") {
                let value = String(line.dropFirst("# branch.head ".count)).trimmingCharacters(in: .whitespaces)
                if value == "(detached)" {
                    detached = true
                } else if !value.isEmpty {
                    branch = value
                }
            } else if line.hasPrefix("# branch.ab ") {
                // Format: "# branch.ab +<ahead> -<behind>"
                let tokens = line.dropFirst("# branch.ab ".count).split(separator: " ")
                for token in tokens {
                    if token.hasPrefix("+") { ahead = Int(token.dropFirst()) ?? ahead }
                    else if token.hasPrefix("-") { behind = Int(token.dropFirst()) ?? behind }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") || line.hasPrefix("? ") {
                // Changed (1), renamed/copied (2), unmerged (u), or untracked (?).
                // Ignored ("! ") deliberately does not mark the tree dirty.
                dirty = true
            }
        }

        return GitSessionStatus(
            isRepo: true,
            branch: branch,
            detached: detached,
            dirty: dirty,
            ahead: ahead,
            behind: behind
        )
    }
}

/// Reads `GitSessionStatus` for a directory by shelling out to `git`, bounded by
/// a watchdog so a slow/locked repo can never wedge the caller. Read-only and
/// lock-free (`--no-optional-locks`) so it's safe to run repeatedly alongside a
/// live agent that is committing in the same repo.
public struct GitStatusReader: Sendable {
    public var resolvedGitPath: String?
    public var timeout: TimeInterval

    public init(
        environment: TerminalEnvironment = TerminalEnvironment(),
        timeout: TimeInterval = 3,
        fileManager: FileManager = .default
    ) {
        self.timeout = timeout
        self.resolvedGitPath = Self.resolveGit(environment: environment, fileManager: fileManager)
    }

    /// Resolve a usable `git` absolute path: common macOS locations first, then PATH.
    static func resolveGit(environment: TerminalEnvironment, fileManager: FileManager) -> String? {
        let known = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        for path in known where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        let dirs = TerminalEnvironment.resolvedPath(from: environment.values).split(separator: ":")
        for dir in dirs {
            let candidate = "\(dir)/git"
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Status for `directory`. Returns `.notARepo` when git is unavailable, the
    /// directory isn't a repo, or the call times out.
    public func status(forDirectory directory: String) -> GitSessionStatus {
        guard let gitPath = resolvedGitPath, !directory.isEmpty else {
            return .notARepo
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = [
            "--no-optional-locks",
            "-C", directory,
            "status", "--porcelain=v2", "--branch"
        ]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            let start = Date()
            try process.run()
            let watchdog = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            guard Date().timeIntervalSince(start) < timeout, process.terminationStatus == 0 else {
                return .notARepo
            }
            return GitSessionStatus.parse(porcelainV2: String(decoding: data, as: UTF8.self))
        } catch {
            return .notARepo
        }
    }
}
