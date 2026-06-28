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
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0"),
        // TEST-ONLY (operator-ratification item, D-U1-DEP). ViewInspector is the
        // only in-process tool that invokes SwiftUI child bodies (composed surfaces
        // visible → real negative control) AND extracts DECLARED content (no
        // VM-graph machine-path leak) AND absorbs SwiftUI renames — the prerequisites
        // the AX source (out-of-process in xctest) and Mirror (opaque leaves + 25
        // leaked /Users paths) both failed. Pinned EXACT for reproducible CI; linked
        // into the `OuroWorkbenchAppViewsTests` test target ONLY (never the .app /
        // any product/runtime/distribution surface). Reversible in one PR.
        .package(url: "https://github.com/nalexn/ViewInspector.git", exact: "0.10.3")
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
                .product(name: "OuroAppShellContract", package: "ouro-native-apple-app-shell"),
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
                "OuroWorkbenchShellAdapter",
                .product(name: "OuroAppShellConsumerTesting", package: "ouro-native-apple-app-shell")
            ]
        ),
        // Proves the extracted views library is `@testable import`-able and that a
        // view it exports constructs across the module boundary — the importability
        // keystone the rest of Phase 0 depends on (U0 Unit 1).
        .testTarget(
            name: "OuroWorkbenchAppViewsTests",
            dependencies: [
                "OuroWorkbenchAppViews",
                // Test-only view-tree introspection (D-U1-DEP). NOT on any product target.
                .product(name: "ViewInspector", package: "ViewInspector")
            ],
            // F-1 (D-U1-2): committed `__Snapshots__/*.txt` references live next to the
            // test source and are read BY PATH (`#filePath`-relative), never bundled. Without
            // this exclude SwiftPM emits an "unhandled file" build-PLAN warning for them.
            // `exclude:` (not `resources:`) is correct because they must NOT be copied into
            // the test bundle. This touches one array on one test target — no `dependencies`
            // churn beyond the line above, no COVERAGE_DIRS / allowlist change.
            exclude: ["__Snapshots__"]
        )
    ]
)
