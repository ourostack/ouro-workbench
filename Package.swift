// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OuroWorkbench",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OuroWorkbenchCore", targets: ["OuroWorkbenchCore"]),
        .executable(name: "OuroWorkbench", targets: ["OuroWorkbenchApp"]),
        .executable(name: "OuroWorkbenchMCP", targets: ["OuroWorkbenchMCP"]),
        .executable(name: "OuroWorkbenchScenarioVerifier", targets: ["OuroWorkbenchScenarioVerifier"])
    ],
    dependencies: [
        .package(url: "https://github.com/ourostack/ouro-native-apple-app-shell.git", branch: "main"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0")
    ],
    targets: [
        .target(
            name: "OuroWorkbenchCore",
            dependencies: [
                .product(name: "OuroAppShellCore", package: "ouro-native-apple-app-shell")
            ]
        ),
        .target(
            name: "OuroWorkbenchShellAdapter",
            dependencies: [
                "OuroWorkbenchCore",
                .product(name: "OuroAppShellUI", package: "ouro-native-apple-app-shell")
            ]
        ),
        // The extracted AppKit/SwiftUI views library (U0). The 121 `View` structs +
        // `WorkbenchViewModel` + the coupled PTY/controller types move here so they
        // become `@testable import`-able and coverage-gateable (impossible against an
        // executableTarget). This is the FIRST AppKit/SwiftUI-importing library target
        // in the package — fully supported on macOS .v14 (AppKit/SwiftUI are system
        // frameworks any linking target may import). U0 Unit 1 seeds it with one leaf
        // view (DashboardRowLabel); the rest move in later increments.
        .target(
            name: "OuroWorkbenchAppViews",
            dependencies: [
                "OuroWorkbenchCore",
                "OuroWorkbenchShellAdapter",
                .product(name: "OuroAppShellUI", package: "ouro-native-apple-app-shell"),
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        .executableTarget(
            name: "OuroWorkbenchApp",
            dependencies: [
                "OuroWorkbenchAppViews",
                "OuroWorkbenchCore",
                "OuroWorkbenchShellAdapter",
                .product(name: "OuroAppShellUI", package: "ouro-native-apple-app-shell"),
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        .executableTarget(
            name: "OuroWorkbenchMCP",
            dependencies: ["OuroWorkbenchCore"]
        ),
        .executableTarget(
            name: "OuroWorkbenchScenarioVerifier",
            dependencies: ["OuroWorkbenchCore"]
        ),
        .testTarget(
            name: "OuroWorkbenchCoreTests",
            dependencies: [
                "OuroWorkbenchCore",
                "OuroWorkbenchShellAdapter"
            ]
        ),
        // Proves the extracted views library is `@testable import`-able and that a
        // view it exports constructs across the module boundary — the importability
        // keystone the rest of Phase 0 depends on (U0 Unit 1).
        .testTarget(
            name: "OuroWorkbenchAppViewsTests",
            dependencies: [
                "OuroWorkbenchAppViews"
            ]
        )
    ]
)
