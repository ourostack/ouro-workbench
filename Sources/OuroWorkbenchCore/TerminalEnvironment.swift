import Foundation

/// Per-session Workbench context layered onto a launched terminal's environment
/// so the agent inside can detect and describe its host. The always-on markers
/// (`OURO_WORKBENCH`, `OURO_WORKBENCH_VERSION`, `TERM_PROGRAM`) are set even when
/// no context is supplied; the contextual fields are emitted only when present.
public struct WorkbenchSessionContext: Equatable, Sendable {
    public var contextFilePath: String?
    public var group: String?
    public var session: String?
    public var boss: String?

    public init(
        contextFilePath: String? = nil,
        group: String? = nil,
        session: String? = nil,
        boss: String? = nil
    ) {
        self.contextFilePath = contextFilePath
        self.group = group
        self.session = session
        self.boss = boss
    }

    /// The contextual environment variables, omitting any unset field so the
    /// agent never sees an empty `OURO_WORKBENCH_GROUP=`.
    public var environmentVariables: [String: String] {
        var values: [String: String] = [:]
        if let contextFilePath, !contextFilePath.isEmpty {
            values["OURO_WORKBENCH_CONTEXT_FILE"] = contextFilePath
        }
        if let group, !group.isEmpty {
            values["OURO_WORKBENCH_GROUP"] = group
        }
        if let session, !session.isEmpty {
            values["OURO_WORKBENCH_SESSION"] = session
        }
        if let boss, !boss.isEmpty {
            values["OURO_WORKBENCH_BOSS"] = boss
        }
        return values
    }
}

public struct TerminalEnvironment: Equatable, Sendable {
    public var values: [String: String]
    public var workbenchContext: WorkbenchSessionContext?

    /// The user's real login-shell PATH (`$SHELL -lc 'echo $PATH'`), captured once at
    /// app launch. A hardcoded dir list can NEVER locate a version-manager `node`
    /// (nvm/asdf put it under a dynamic version path), and `ouro` is a `node` script —
    /// so without the login PATH every `ouro` shellout dies with "node: not found".
    /// Using the real shell env makes nvm/brew/asdf/etc. all just work. Set once at
    /// launch on the main thread, read-only thereafter (hence `nonisolated(unsafe)`).
    public nonisolated(unsafe) static var loginShellPath: String?

    public init(
        values: [String: String] = ProcessInfo.processInfo.environment,
        workbenchContext: WorkbenchSessionContext? = nil
    ) {
        self.values = values
        self.workbenchContext = workbenchContext
    }

    public func mergedWithTerminalDefaults() -> [String] {
        valuesWithResolvedPath()
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
    }

    public func valuesWithResolvedPath() -> [String: String] {
        var merged = values
        merged["TERM"] = "xterm-256color"
        // Do NOT advertise truecolor. The persistent sessions run inside GNU
        // `screen` 4.00.03 (the build bundled with macOS), which predates 24-bit
        // truecolor and MANGLES `\e[38;2;r;g;b` / `\e[48;2;…` sequences. Agent
        // TUIs (Claude Code, Codex) emit exactly those when they see
        // `COLORTERM=truecolor`, and the mangled bytes render as garish
        // background "chips" — the awful terminal rendering. Removing COLORTERM
        // drops them to 256-color, which `screen` relays faithfully and which
        // renders cleanly (verified: Claude Code's welcome screen, logo, and
        // headings all correct). Revisit if Workbench ever ships a
        // truecolor-capable `screen` (≥ 5.0) or switches multiplexer.
        merged.removeValue(forKey: "COLORTERM")
        merged["LANG"] = merged["LANG"] ?? "en_US.UTF-8"
        merged["TERM_PROGRAM"] = "OuroWorkbench"
        // Always-on markers so any session Workbench launches can detect its host.
        merged["OURO_WORKBENCH"] = "1"
        merged["OURO_WORKBENCH_VERSION"] = WorkbenchRelease.version
        if let workbenchContext {
            for (key, value) in workbenchContext.environmentVariables {
                merged[key] = value
            }
        }
        // Base the PATH on the user's real login shell (captured at launch) so a
        // version-manager `node` + `ouro` resolve. `resolvedPath` then layers the
        // known fallback dirs on top (deduped), so behaviour is unchanged when no
        // login PATH was captured.
        if let loginPath = Self.loginShellPath, !loginPath.isEmpty {
            let existing = merged["PATH"] ?? ""
            merged["PATH"] = existing.isEmpty ? loginPath : "\(loginPath):\(existing)"
        }
        merged["PATH"] = Self.resolvedPath(from: merged)
        return merged
    }

    public static func resolvedPath(from values: [String: String]) -> String {
        let existing = values["PATH"]?.split(separator: ":").map(String.init) ?? []
        let homeLocalBin = values["HOME"].map { "\($0)/.local/bin" }
        // The `ouro` CLI installs to `~/.ouro-cli/bin` (CurrentVersion symlink) and is
        // present nowhere else — not in homebrew, /usr/local, or ~/.local/bin. A
        // Finder/login-launched app inherits the bare launchd PATH (no login-shell
        // additions), so without this entry every `/usr/bin/env ouro …` shellout
        // (daemon bringup, hatch, verify, the mcp-serve bridge) fails to resolve `ouro`
        // on a clean install. Keep this ahead of the system dirs so it always wins.
        let ouroCliBin = values["HOME"].map { "\($0)/.ouro-cli/bin" }
        let defaults = [
            homeLocalBin,
            ouroCliBin,
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].compactMap { $0 }
        var seen = Set<String>()
        return (existing + defaults)
            .filter { component in
                guard !component.isEmpty, !seen.contains(component) else {
                    return false
                }
                seen.insert(component)
                return true
            }
            .joined(separator: ":")
    }
}
