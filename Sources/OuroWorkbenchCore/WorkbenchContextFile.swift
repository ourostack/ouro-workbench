import Foundation

/// Writes the inner-agent context document (see `WorkbenchGuide.innerAgentContext`)
/// to Application Support and hands back its path. Workbench refreshes this file
/// on launch and points `OURO_WORKBENCH_CONTEXT_FILE` at it for every terminal
/// session, so an agent can read one file to learn where it is running.
public enum WorkbenchContextFile {
    /// Stable on-disk location: `…/Application Support/OuroWorkbench/agent-context.md`.
    public static func defaultURL(paths: WorkbenchPaths = .defaultPaths()) -> URL {
        paths.rootURL.appendingPathComponent("agent-context.md")
    }

    /// Render the current context document and write it atomically, creating the
    /// parent directory if needed. Returns the written URL.
    @discardableResult
    public static func write(
        to url: URL = defaultURL(),
        version: String = WorkbenchRelease.version,
        boss: String?,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let content = WorkbenchGuide.innerAgentContext(version: version, boss: boss)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
