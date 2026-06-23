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
        .executableTarget(
            name: "OuroWorkbenchApp",
            dependencies: [
                "OuroWorkbenchCore",
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
            dependencies: ["OuroWorkbenchCore"]
        )
    ]
)
