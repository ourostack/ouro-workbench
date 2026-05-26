#if os(macOS)
import Darwin
import Foundation
import SwiftUI

if CommandLine.arguments.contains("--smoke-launch") {
    let swiftTermBundleURL = Bundle.main.resourceURL?
        .appendingPathComponent("SwiftTerm_SwiftTerm.bundle", isDirectory: true)
    guard let swiftTermBundleURL, FileManager.default.fileExists(atPath: swiftTermBundleURL.path) else {
        let resourcePath = Bundle.main.resourceURL?.path ?? "<missing resource directory>"
        FileHandle.standardError.write(Data("Missing SwiftTerm resource bundle under \(resourcePath)\n".utf8))
        Darwin.exit(1)
    }

    FileHandle.standardOutput.write(Data("OuroWorkbench smoke launch ok\n".utf8))
    Darwin.exit(0)
}

OuroWorkbenchApp.main()
#endif
