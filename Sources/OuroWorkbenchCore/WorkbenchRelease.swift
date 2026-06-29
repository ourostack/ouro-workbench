import Foundation

public enum WorkbenchRelease {
    public static let appName = "Ouro Workbench"
    public static let bundleIdentifier = "com.ourostack.workbench"
    public static let bundleExecutable = "OuroWorkbench"
    public static let mcpExecutable = "OuroWorkbenchMCP"
    public static let mcpServerName = "ouro-workbench"
    public static let artifactNamePrefix = "\(bundleExecutable)-"
    public static let version = "0.1.228"
    public static let repository = "ourostack/ouro-workbench"
    public static let minimumMacOSVersion = "14.0"
    /// Where in-app bug reports are filed when the operator chooses the GitHub
    /// Issue venue (`owner/repo`).
    public static let issueRepo = repository

    public static func userAgent(version: String = Self.version) -> String {
        "OuroWorkbench/\(version)"
    }
}
