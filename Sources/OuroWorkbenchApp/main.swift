#if os(macOS)
import Darwin
import Foundation
import SwiftUI

if CommandLine.arguments.contains("--smoke-launch") {
    let swiftTermBundleURL = Bundle.main.bundleURL
        .appendingPathComponent("SwiftTerm_SwiftTerm.bundle", isDirectory: true)
    guard FileManager.default.fileExists(atPath: swiftTermBundleURL.path) else {
        FileHandle.standardError.write(Data("Missing SwiftTerm resource bundle at \(swiftTermBundleURL.path)\n".utf8))
        Darwin.exit(1)
    }

    FileHandle.standardOutput.write(Data("OuroWorkbench smoke launch ok\n".utf8))
    Darwin.exit(0)
}

OuroWorkbenchApp.main()
#endif
