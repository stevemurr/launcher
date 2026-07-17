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
    targets: [
        .executableTarget(
            name: "Launcher",
            path: "Sources/Launcher",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
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
