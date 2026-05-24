import Foundation

public enum LaunchAgentLoginItemStatus: String, Equatable {
    case enabled
    case needsUpdate
    case notInstalled
    case appBundleMissing
}

public enum LaunchAgentLoginItemError: Error, Equatable, LocalizedError {
    case appBundleMissing(String)

    public var errorDescription: String? {
        switch self {
        case .appBundleMissing(let path):
            return "App bundle is missing at \(path)"
        }
    }
}

public struct LaunchAgentLoginItem {
    public var label: String
    public var appURL: URL
    public var homeURL: URL
    public var fileManager: FileManager

    public init(
        label: String = "com.ourostack.workbench.login",
        appURL: URL,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.label = label
        self.appURL = appURL
        self.homeURL = homeURL
        self.fileManager = fileManager
    }

    public static func defaultAppURL(
        bundleURL: URL = Bundle.main.bundleURL,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if bundleURL.pathExtension == "app" {
            return bundleURL
        }
        return homeURL
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Ouro Workbench.app", isDirectory: true)
    }

    public var plistURL: URL {
        homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    public var logDirectoryURL: URL {
        homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("OuroWorkbench", isDirectory: true)
    }

    public func status() -> LaunchAgentLoginItemStatus {
        guard fileManager.fileExists(atPath: appURL.path) else {
            return .appBundleMissing
        }
        guard fileManager.fileExists(atPath: plistURL.path) else {
            return .notInstalled
        }
        guard plistMatchesCurrentApp() else {
            return .needsUpdate
        }
        return .enabled
    }

    public func install() throws {
        guard fileManager.fileExists(atPath: appURL.path) else {
            throw LaunchAgentLoginItemError.appBundleMissing(appURL.path)
        }

        try fileManager.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: logDirectoryURL,
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", appURL.path],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": logDirectoryURL.appendingPathComponent("login.out.log").path,
            "StandardErrorPath": logDirectoryURL.appendingPathComponent("login.err.log").path
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL, options: [.atomic])
    }

    public func uninstall() throws {
        guard fileManager.fileExists(atPath: plistURL.path) else {
            return
        }
        try fileManager.removeItem(at: plistURL)
    }

    private func plistMatchesCurrentApp() -> Bool {
        guard
            let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            let programArguments = plist["ProgramArguments"] as? [String]
        else {
            return false
        }
        return programArguments == ["/usr/bin/open", appURL.path]
    }
}
