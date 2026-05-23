import Foundation

public struct WorkbenchPaths: Sendable {
    public var rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public static func defaultPaths(fileManager: FileManager = .default) -> WorkbenchPaths {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return WorkbenchPaths(rootURL: appSupport.appendingPathComponent("OuroWorkbench", isDirectory: true))
    }

    public var stateURL: URL {
        rootURL.appendingPathComponent("workspace-state.json")
    }

    public var transcriptsURL: URL {
        rootURL.appendingPathComponent("transcripts", isDirectory: true)
    }

    public func transcriptURL(entryId: UUID, runId: UUID) -> URL {
        transcriptsURL
            .appendingPathComponent(entryId.uuidString, isDirectory: true)
            .appendingPathComponent("\(runId.uuidString).log")
    }
}
