// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Launcher",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Launcher", targets: ["Launcher"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/stevemurr/libghostty-spm",
            revision: "ca4cffd668f958e1fe5da9cbf31f460f3ba01533"
        )
    ],
    targets: [
        .executableTarget(
            name: "Launcher",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm")
            ],
            path: "Sources/Launcher",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "LauncherTests",
            dependencies: ["Launcher"],
            path: "Tests/LauncherTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
