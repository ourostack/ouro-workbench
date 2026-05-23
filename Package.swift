// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OuroWorkbench",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OuroWorkbenchCore", targets: ["OuroWorkbenchCore"]),
        .executable(name: "OuroWorkbench", targets: ["OuroWorkbenchApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0")
    ],
    targets: [
        .target(
            name: "OuroWorkbenchCore"
        ),
        .executableTarget(
            name: "OuroWorkbenchApp",
            dependencies: [
                "OuroWorkbenchCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        .testTarget(
            name: "OuroWorkbenchCoreTests",
            dependencies: ["OuroWorkbenchCore"]
        )
    ]
)
